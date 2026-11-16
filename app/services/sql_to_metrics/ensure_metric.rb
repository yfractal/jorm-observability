# frozen_string_literal: true

module SqlToMetrics
  # Entry point that routes analytics SQL to the matching *Metrics::EnsureMetric.
  class EnsureMetric
    Result = EnsureMetricBase::Result

    def initialize(sql)
      @sql = sql.to_s
    end

    def call
      case QueryKind.call(@sql)
      when :histogram then HistogramMetrics::EnsureMetric.new(@sql).call
      when :gauge then GaugeMetrics::EnsureMetric.new(@sql).call
      when :counter then CounterMetrics::EnsureMetric.new(@sql).call
      else
        Result.new(metric_name: nil, created: false, enqueued_backfill: false)
      end
    end
  end
end
