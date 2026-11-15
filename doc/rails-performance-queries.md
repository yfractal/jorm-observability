# Rails Performance dashboard queries

Dashboard JSON: [rails-performance.json](rails-performance.json) (same file Grafana provisions from `grafana/dashboards/performance.json`).

`$per` is `1 minute`, `5 minutes`, `10 minutes`, `30 minutes`, or `1 hour`.

This app materializes **counter**, **gauge**, and **histogram** metrics (`TraceToMetric::METRIC_TYPES`). Histograms store UDDSketch states (`uddsketch_state`) per bucket and read them back with `uddsketch_merge` / `uddsketch_calc`, so p99/p95/p50 and every `$per` share one table.

`COUNT(*)` is a counter. `AVG(duration_nano)` is a gauge: the metric table stores per-bucket `value_sum` / `value_count` (append-only), and reads compute `SUM(value_sum) / SUM(value_count)` (with the query's `/ 1e6` scale). That mean rolls up when `$per` changes. `approx_percentile_cont(duration_nano, p)` is a read of a histogram of `duration_nano`. Storing p99 itself would be a gauge that cannot be re-aggregated when `$per` changes.

## Counter

### 1. Requests served

```sql
SELECT COUNT(*) AS value
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND span_kind = 'SPAN_KIND_SERVER'
  AND "span_attributes.http.response.status_code" IS NOT NULL
```

### 2. Jobs Executed

```sql
SELECT COUNT(*) AS value
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
```

### 3. Mails Sent

```sql
SELECT COUNT(*) AS value
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActionMailer'
```

### 4. Requests per $per — ok

```sql
SELECT date_bin('$per', timestamp) AS time, COUNT(*) AS ok
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND span_kind = 'SPAN_KIND_SERVER'
  AND "span_attributes.http.response.status_code" IS NOT NULL
  AND "span_attributes.http.response.status_code" < 400
GROUP BY time
ORDER BY time
```

### 5. Requests per $per — error

```sql
SELECT date_bin('$per', timestamp) AS time, COUNT(*) AS error
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND span_kind = 'SPAN_KIND_SERVER'
  AND "span_attributes.http.response.status_code" IS NOT NULL
  AND "span_attributes.http.response.status_code" >= 400
GROUP BY time
ORDER BY time
```

### 6. Jobs per $per — succeeded

```sql
SELECT date_bin('$per', timestamp) AS time, COUNT(*) AS succeeded
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
  AND (span_status_code IS NULL OR span_status_code != 'STATUS_CODE_ERROR')
GROUP BY time
ORDER BY time
```

### 7. Jobs per $per — failed

```sql
SELECT date_bin('$per', timestamp) AS time, COUNT(*) AS failed
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
  AND span_status_code = 'STATUS_CODE_ERROR'
GROUP BY time
ORDER BY time
```

### 8. Mails per $per

```sql
SELECT date_bin('$per', timestamp) AS time, COUNT(*) AS mails
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActionMailer'
GROUP BY time
ORDER BY time
```

## Gauge

Metric-backed via `SqlToMetrics::Gauge::*` (verify with `bin/rails runner script/check_gauge_metric_backfill.rb`).

### Average Response

```sql
SELECT AVG(duration_nano) / 1e6 AS value
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND span_kind = 'SPAN_KIND_SERVER'
  AND "span_attributes.http.response.status_code" IS NOT NULL
```

### Average Database Response

```sql
SELECT AVG(duration_nano) / 1e6 AS value
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND "span_attributes.db.system" IS NOT NULL
```

### Average Job Execution

```sql
SELECT AVG(duration_nano) / 1e6 AS value
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
```

### Controller Action Performance — mean

```sql
SELECT date_bin('$per', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND span_kind = 'SPAN_KIND_SERVER'
  AND "span_attributes.http.response.status_code" IS NOT NULL
GROUP BY time
ORDER BY time
```

### Database Query Performance — mean

```sql
SELECT date_bin('$per', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND "span_attributes.db.system" IS NOT NULL
GROUP BY time
ORDER BY time
```

### ActiveJob Performance — mean

```sql
SELECT date_bin('$per', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
GROUP BY time
ORDER BY time
```

## Histogram

Served from a histogram metric (verify with `bin/rails runner script/check_histogram_metric_backfill.rb`). Each panel runs the same statement three times, with quantile `0.99` (`p99`), `0.95` (`p95`), and `0.50` (`p50`).

### Controller Action Performance — p99 / p95 / p50

```sql
SELECT date_bin('$per', timestamp) AS time,
       approx_percentile_cont(duration_nano, 0.99) / 1e6 AS p99
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND span_kind = 'SPAN_KIND_SERVER'
  AND "span_attributes.http.response.status_code" IS NOT NULL
GROUP BY time
ORDER BY time
```

### Database Query Performance — p99 / p95 / p50

```sql
SELECT date_bin('$per', timestamp) AS time,
       approx_percentile_cont(duration_nano, 0.99) / 1e6 AS p99
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND "span_attributes.db.system" IS NOT NULL
GROUP BY time
ORDER BY time
```

### ActiveJob Performance — p99 / p95 / p50

```sql
SELECT date_bin('$per', timestamp) AS time,
       approx_percentile_cont(duration_nano, 0.99) / 1e6 AS p99
FROM opentelemetry_traces
WHERE timestamp >= from_unixtime(${__from}/1000)
  AND timestamp < from_unixtime(${__to}/1000)
  AND ('$service_name' = '__all__' OR service_name = '$service_name')
  AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
GROUP BY time
ORDER BY time
```
