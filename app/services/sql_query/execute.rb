module SqlQuery
  class Execute
    def self.call(sql)
      new(sql).call
    end

    def initialize(sql)
      @sql = sql
    end

    def call
      validated = ReadOnly.validate!(@sql)
      SqlToMetrics::EnsureMetric.call(validated)
      run_with_metric_fallback(validated)
    end

    private

    def run_with_metric_fallback(sql)
      SqlToMetrics::HybridQuery.call(sql)
    rescue SqlToMetrics::UnsupportedError, SqlToMetrics::ParseError
      SqlToMetrics::HybridQuery.call(sql, use_metric: false)
    end
  end
end
