# frozen_string_literal: true

module HistogramMetrics
  # Same flow as CounterMetrics::EnsureMetric (definition, watermark, backfill job);
  # only the spec and the stored definition differ.
  class EnsureMetric < SqlToMetrics::EnsureMetricBase
    private

    def build_spec
      Spec.call(@sql)
    end

    def create_definition!(spec)
      TraceToMetric.create!(
        name: spec[:name],
        span_name: TraceToMetric::QUERY_SPAN_NAME,
        metric_type: "histogram",
        value_column: spec[:value_column],
        dimensions: Array(spec[:dimensions]),
        filters: Array(spec[:filters]),
        bucket_interval: spec[:bucket_interval]
      )
    end
  end
end
