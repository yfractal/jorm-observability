# jorm-observability

Rails app that ingests OTLP traces and derives counter metrics.

## Databases

| Role | Engine | Default connection |
|------|--------|--------------------|
| **primary** | [GreptimeDB](https://greptime.com/) via PostgreSQL wire protocol (`pg` gem) | `127.0.0.1:4003` / database `public` (dev), `jorm_observability_test` (test) |
| **queue** | PostgreSQL (solid_queue only) | `jorm_observability_*_queue` |

GreptimeDB is not a drop-in Postgres server: tables use a TIME INDEX, counters are append-only (`value=1` rows aggregated with `SUM`), and definition updates use insert-overwrite instead of `UPDATE`.

## Quick start

```bash
docker compose up -d
bin/rails greptime:prepare
bin/rails db:prepare   # also prepares the PostgreSQL queue DB
bin/rails server
```

Grafana (provisioned **Traces** and **Rails Performance** dashboards) is at [http://localhost:5001](http://localhost:5001). It queries GreptimeDB only through this app — keep `bin/rails server` running on port 3000.

The Performance dashboard maps OTLP spans to Rails-style panels: Rack `SPAN_KIND_SERVER` for requests/latency, `db.system` for DB query latency, and ActiveJob/ActionMailer `scope_name` for jobs/mails when that instrumentation is present. Instantiation is omitted (OTel has no `record_count`).

### Environment

- `GREPTIME_HOST` (default `127.0.0.1`)
- `GREPTIME_PORT` (default `4003`)
- `GREPTIME_DATABASE` (default `public`, development/production)
- `GREPTIME_TEST_DATABASE` (default `jorm_observability_test` — RSpec never uses `public`)
- `GREPTIME_HTTP` (default `http://$GREPTIME_HOST:4000`, used to `CREATE DATABASE`)
- `GREPTIME_USERNAME` / `GREPTIME_PASSWORD` (optional)
- `DATABASE_URL` (optional full URL for primary, e.g. `postgres://@127.0.0.1:4003/public`)
- `QUEUE_DATABASE_URL` (production queue)

## Grafana / SQL proxy

`POST /api/v1/sql` accepts a read-only `SELECT` (including `WITH … SELECT`) and runs it via `SqlToMetrics::HybridQuery` against GreptimeDB:

```bash
curl -s http://127.0.0.1:3000/api/v1/sql \
  -H 'content-type: application/json' \
  -d '{"sql":"SELECT service_name, COUNT(*) AS count FROM opentelemetry_traces GROUP BY service_name"}'
```

Response shape: `{ "data": [ ...rows ], "sql": "...", "used_metric": bool, "metric_name": ... }`.

Supported `COUNT` queries also create a counter metric (when every `WHERE` predicate is `=`, comparisons, `IS NULL`, `IS NOT NULL`, or `(col IS NULL OR col != value)`), store a backfill watermark on `trace_to_metrics`, and enqueue `TraceToMetrics::BackfillJob` for existing spans. Live `OpentelemetryTraceCreatedJob` writes only spans after that watermark.

Verify dashboard counters after backfill with `bin/rails runner script/check_counter_metric_backfill.rb` (run `bin/jobs` so backfill jobs execute).

Non-SELECT statements are rejected (`422`). There is no auth on this endpoint yet — do not expose it publicly without adding authentication.

Compose services: GreptimeDB, Postgres (queue), and Grafana (Infinity datasource → `host.docker.internal:3000`).

## Metric-backed COUNT queries

`SqlToMetrics::HybridQuery` rewrites a `COUNT` analytics query into a single GreptimeDB statement that reads a pre-aggregated metric table for the time range it covers and the raw `opentelemetry_traces` table for the remainder (`UNION ALL` + outer `SUM`).

```ruby
result = SqlToMetrics::HybridQuery.call(<<~SQL)
  SELECT date_bin('1 minute', timestamp) AS time, scope_name, COUNT(*) AS count
  FROM opentelemetry_traces
  WHERE timestamp >= '2026-01-01 00:00:00' AND timestamp < '2026-01-02 00:00:00'
  GROUP BY scope_name, time
SQL
result.rows
result.used_metric  # true when a compatible metric table was used

# Skip rewrite and run the input SQL as-is
SqlToMetrics::HybridQuery.call(sql, use_metric: false)
```

Metric tables are derived with `SqlToMetrics::TableSpec` (see `script/create_scope_name_minute_metrics.rb`). Coverage is `MIN(bucket)` .. `min(MAX(bucket)+interval, floor(now))` so only the current open bucket is read from raw data.

## Histogram metrics

`approx_percentile_cont(col, q)` queries (the dashboard's p99/p95/p50 panels) are served from histogram metrics: a `BINARY` UDDSketch column per `(bucket, dimensions)`, backfilled by the same `TraceToMetrics::BackfillJob`, appended live by `OpentelemetryTraceCreatedJob`, and read as metric segment + raw segment, merged. Results are approximate (about 1% sketch error). All histogram code lives under `app/services/histogram_metrics/`. Verify with `bin/rails runner script/check_histogram_metric_backfill.rb` (seed ActiveJob durations first with `script/seed_histogram_metric_traces.rb`). Existing databases need `bin/rails greptime:prepare` to add `trace_to_metrics.value_column`.

## Tests

Start GreptimeDB (and Postgres if exercising queue), then:

```bash
docker compose up -d greptimedb
bin/rails greptime:prepare
bundle exec rspec
```
