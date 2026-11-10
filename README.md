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

## Tests

Start GreptimeDB (and Postgres if exercising queue), then:

```bash
docker compose up -d greptimedb
bin/rails greptime:prepare
bundle exec rspec
```
