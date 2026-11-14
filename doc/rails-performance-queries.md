# Rails Performance dashboard queries

Dashboard JSON: [rails-performance.json](rails-performance.json) (same file Grafana provisions from `grafana/dashboards/performance.json`).

Every panel query shares this filter. `$per` is `1 minute`, `5 minutes`, `10 minutes`, `30 minutes`, or `1 hour`.

```sql
timestamp >= from_unixtime(${__from}/1000)
AND timestamp < from_unixtime(${__to}/1000)
AND ('$service_name' = '__all__' OR service_name = '$service_name')
```

This app only materializes **counter** metrics (`TraceToMetric::METRIC_TYPES`, `SqlToMetrics::Mapper`). Gauge and histogram below are the type each query would need; they are not implemented.

## Counter

`COUNT(*)` is a counter: one span is one increment, and buckets add with `SUM`. `SqlToMetrics::Mapper` already classifies `count` as `counter`.

| Panel | Series | Extra filter |
| --- | --- | --- |
| Requests served | `value` | `span_kind = 'SPAN_KIND_SERVER' AND "span_attributes.http.response.status_code" IS NOT NULL` |
| Jobs Executed | `value` | `scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'` |
| Mails Sent | `value` | `scope_name = 'OpenTelemetry::Instrumentation::ActionMailer'` |
| Requests per $per | `ok` | request filter AND status `< 400` |
| Requests per $per | `error` | request filter AND status `>= 400` |
| Jobs per $per | `succeeded` | ActiveJob AND `span_status_code` is not `STATUS_CODE_ERROR` |
| Jobs per $per | `failed` | ActiveJob AND `span_status_code = 'STATUS_CODE_ERROR'` |
| Mails per $per | `mails` | ActionMailer |

```sql
SELECT COUNT(*) AS value
FROM opentelemetry_traces
WHERE <shared> AND <extra filter>

SELECT date_bin('$per', timestamp) AS time, COUNT(*) AS ok
FROM opentelemetry_traces
WHERE <shared> AND <extra filter>
GROUP BY time
ORDER BY time
```

## Gauge

`AVG(duration_nano) / 1e6` can be stored as a gauge: a point value for that window that is not a running total. It is not a counter. `Mapper` returns no metric type for `AVG`.

A gauge of averages does not roll up. Summing or averaging those gauges across buckets is wrong. If duration is a histogram, the mean is `sum / count` and these panels do not need their own gauge.

| Panel | Extra filter |
| --- | --- |
| Average Response | request spans |
| Average Database Response | `"span_attributes.db.system" IS NOT NULL` |
| Average Job Execution | ActiveJob |
| Controller Action Performance `mean` | request spans, `date_bin('$per', timestamp)` |
| Database Query Performance `mean` | db spans, `date_bin('$per', timestamp)` |
| ActiveJob Performance `mean` | ActiveJob, `date_bin('$per', timestamp)` |

```sql
SELECT AVG(duration_nano) / 1e6 AS value
FROM opentelemetry_traces
WHERE <shared> AND <extra filter>

SELECT date_bin('$per', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
FROM opentelemetry_traces
WHERE <shared> AND <extra filter>
GROUP BY time
ORDER BY time
```

## Histogram

`approx_percentile_cont(duration_nano, p)` is a read of a distribution, so the metric type is a histogram of `duration_nano` (buckets plus sum and count). The percentile is computed from that distribution. Storing p99 itself would be a gauge, and that gauge cannot be re-aggregated when `$per` changes.

The same histogram also yields the mean (`sum / count`), which covers the gauge panels above.

| Panel | Series | Quantile |
| --- | --- | --- |
| Controller Action Performance | `p99`, `p95`, `p50` | 0.99, 0.95, 0.50 on request spans |
| Database Query Performance | `p99`, `p95`, `p50` | 0.99, 0.95, 0.50 on db spans |
| ActiveJob Performance | `p99`, `p95`, `p50` | 0.99, 0.95, 0.50 on ActiveJob spans |

```sql
SELECT date_bin('$per', timestamp) AS time,
       approx_percentile_cont(duration_nano, 0.99) / 1e6 AS p99
FROM opentelemetry_traces
WHERE <shared> AND <extra filter>
GROUP BY time
ORDER BY time
```

`p95` uses `0.95`, `p50` uses `0.50`. The filter matches the panel: request spans, `"span_attributes.db.system" IS NOT NULL`, or ActiveJob.
