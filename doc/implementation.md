
POST /api/v1/sql
  → SqlQuery::Execute
    → SqlToMetrics::EnsureMetric.new(sql).call
        → SqlToMetrics::QueryKind.call(sql)  # :histogram | :gauge | :counter | :unsupported
        → HistogramMetrics::EnsureMetric / GaugeMetrics::EnsureMetric / CounterMetrics::EnsureMetric
           # :unsupported skips ensure (no metric created)
           # may enqueue TraceToMetrics::BackfillJob
    → SqlToMetrics::HybridQuery.call(sql)    # read (MV + raw hybrid via *Metrics::QueryRewriter)
