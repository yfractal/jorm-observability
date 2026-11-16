
POST /api/v1/sql
  → SqlQuery::Execute
    → SqlToMetrics::EnsureMetric.new(sql).call
        → SqlToMetrics::QueryKind.call(sql)  # :histogram | :gauge | :counter
        → HistogramMetrics::EnsureMetric / GaugeMetrics::EnsureMetric / CounterMetrics::EnsureMetric
           # may enqueue TraceToMetrics::BackfillJob
    → SqlToMetrics::HybridQuery.call(sql)    # read (MV + raw hybrid via *Metrics::QueryRewriter)
