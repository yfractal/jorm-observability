# Architecture

## Key Idea

Maintain metrics based on query; use the metrics to speed up query as it doesn't require do aggregation.

## Query optimization

1. Maintain metric(materialized view) based on traces query
2. Use the metric(materialized view) avoid aggregation for the traces query

## Correctness and Concurrency
### Metric Generation
When receive a sql, we determine what kind of metric(materialized view) can be used to avoid aggregation.

Then, when a span has been created, we maintain the metric. It likes otel span to metric connector, but require us to figure out what kind of metrics(materialized view) we need to maintain.

### Query
For a query, if it has relative metric, we query the metric. As the metric may not generated for all existing span, we concat 2 results: metric result and trace result.

For metric query range, the end time is current time - 5 minutes, as we create such metrics concurrently, any give time, a span's metrics are created in 5 minutes. Such assumption is valid and useful -- we can guarantee this and 5 minutes trace query is fast.

## Verification

1. [todo] Compare trace query result with materialized view query result after new materialized view has been created
2. [todo] Use live query to compare 2 results occasionally

## Materialized View Maintenance

1. [todo] Memory limited, in-memory materialized view for ad-hoc query
2. [todo] Calculation limited in DB materialized view for long-lived query

## Use Cases

1. Short ad-hoc query performance improvement — **2x ~ 5x** (tested)
2. Long-lived query in dashboard (e.g. 1 week request count) — **10x ~ 100x** (estimated, but achievable)
3. [todo] Log-based metrics — complex query normally; materialized view benefits much

## AI Usage

1. [todo] Log-based metrics
2. [TBD] Materialized view generation

### Performance targets

| Use case | MV kind | Improvement |
|----------|---------|-------------|
| Ad-hoc analytics | In-memory (todo) | 2x ~ 5x (tested) |
| Dashboard long window | DB MV | 10x ~ 100x (estimated) |
| Log-based metrics (todo) | DB / AI-assisted | Large gain on complex queries |

### Links
1. https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md