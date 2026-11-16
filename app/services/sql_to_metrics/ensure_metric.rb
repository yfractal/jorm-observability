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
      else CounterMetrics::EnsureMetric.new(@sql).call
      end
    end
  end
end
