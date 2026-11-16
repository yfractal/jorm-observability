
POST /api/v1/sql
  → SqlQuery::Execute
    → SqlToMetrics::EnsureMetric.new(sql).call   # may enqueue BackfillJob
    → SqlToMetrics::HybridQuery.call(sql)        # read (MV + raw hybrid)