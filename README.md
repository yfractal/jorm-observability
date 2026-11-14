# jorm-observability

Rails app that ingests OTLP traces and derives counter metrics.

## Databases

| Role | Engine | Default connection |
|------|--------|--------------------|
| **primary** | [GreptimeDB](https://greptime.com/) via PostgreSQL wire protocol (`pg` gem) | `127.0.0.1:4003` / database `public` |
| **queue** | PostgreSQL (solid_queue only) | `jorm_observability_*_queue` |

GreptimeDB is not a drop-in Postgres server: tables use a TIME INDEX, counters are append-only (`value=1` rows aggregated with `SUM`), and definition updates use insert-overwrite instead of `UPDATE`.

## Quick start

```bash
docker compose up -d
bin/rails greptime:prepare
bin/rails db:prepare   # also prepares the PostgreSQL queue DB
bin/rails server
```

### Environment

- `GREPTIME_HOST` (default `127.0.0.1`)
- `GREPTIME_PORT` (default `4003`)
- `GREPTIME_DATABASE` (default `public`)
- `GREPTIME_USERNAME` / `GREPTIME_PASSWORD` (optional)
- `DATABASE_URL` (optional full URL for primary, e.g. `postgres://@127.0.0.1:4003/public`)
- `QUEUE_DATABASE_URL` (production queue)

## Metric-backed COUNT queries

`SqlToMetrics::Runner` rewrites a `COUNT` analytics query into a single GreptimeDB statement that reads a pre-aggregated metric table for the time range it covers and the raw `opentelemetry_traces` table for the remainder (`UNION ALL` + outer `SUM`).

```ruby
result = SqlToMetrics::Runner.call(<<~SQL)
  SELECT date_bin('1 minute', timestamp) AS time, scope_name, COUNT(*) AS count
  FROM opentelemetry_traces
  WHERE timestamp >= '2026-01-01 00:00:00' AND timestamp < '2026-01-02 00:00:00'
  GROUP BY scope_name, time
SQL
result.rows
result.used_metric  # true when a compatible metric table was used

# Skip rewrite and run the input SQL as-is
SqlToMetrics::Runner.call(sql, use_metric: false)
```

Metric tables are derived with `SqlToMetrics::TableSpec` (see `script/create_scope_name_minute_metrics.rb`). Coverage is `MIN(bucket)+interval` .. `MAX(bucket)` so the first and last buckets are always read from raw data.

## Tests

Start GreptimeDB (and Postgres if exercising queue), then:

```bash
docker compose up -d greptimedb
bin/rails greptime:prepare
bundle exec rspec
```
