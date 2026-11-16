# frozen_string_literal: true

module GaugeMetrics
  class EnsureMetric < SqlToMetrics::EnsureMetricBase
    private

    def build_spec
      Spec.call(@sql)
    end

    def create_definition!(spec)
      TraceToMetric.create!(
        name: spec[:name],
        span_name: TraceToMetric::QUERY_SPAN_NAME,
        metric_type: "gauge",
        dimensions: Array(spec[:dimensions]),
        filters: Array(spec[:filters]),
        bucket_interval: spec[:bucket_interval]
      )
    end
  end
end
