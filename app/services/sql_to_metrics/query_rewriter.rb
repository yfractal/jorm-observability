# frozen_string_literal: true

module SqlToMetrics
  # Routes analytics SQL to the matching *Metrics::QueryRewriter.
  # split_ranges stays here as a shared facade used by gauge/histogram.
  class QueryRewriter
    def self.call(sql)
      case QueryKind.call(sql)
      when :histogram then HistogramMetrics::QueryRewriter.call(sql)
      when :gauge then GaugeMetrics::QueryRewriter.call(sql)
      else CounterMetrics::QueryRewriter.call(sql)
      end
    end

    def self.split_ranges(query_range, coverage, bucket_interval)
      CounterMetrics::QueryRewriter.split_ranges(query_range, coverage, bucket_interval)
    end
  end
end
