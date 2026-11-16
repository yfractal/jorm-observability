# frozen_string_literal: true

require "rails_helper"

RSpec.describe GaugeMetrics::Injector, :no_transaction do
  let(:metric_name) { "opentelemetry_traces_avg_duration_nano_gauge" }

  def create_definition!
    TraceToMetric.create!(
      name: metric_name,
      span_name: TraceToMetric::QUERY_SPAN_NAME,
      metric_type: "gauge",
      dimensions: [],
      filters: [],
      bucket_interval: "1 minute"
    )
  end

  def create_trace!(attrs = {})
    OpentelemetryTrace.create!(
      {
        timestamp: Time.utc(2026, 11, 10, 8, 22, 15, 123_456),
        span_name: "http",
        trace_id: SecureRandom.hex(16),
        span_id: SecureRandom.hex(8),
        service_name: "lobsters",
        span_kind: "SPAN_KIND_SERVER",
        duration_nano: 2_000_000,
        span_attributes: {},
        resource_attributes: {}
      }.merge(attrs)
    )
  end

  after { drop_metric_tables(metric_name) }

  it "appends value_sum and value_count from duration_nano" do
    definition = create_definition!
    trace = create_trace!(duration_nano: 5_000_000)

    described_class.call(trace, definition)

    rows = described_class.summed_rows(metric_name)
    expect(rows.size).to eq(1)
    expect(rows.first["value_sum"].to_f).to eq(5_000_000.0)
    expect(rows.first["value_count"].to_i).to eq(1)
  end

  it "aggregates multiple injects in the same second" do
    definition = create_definition!
    first = create_trace!(duration_nano: 1_000_000, timestamp: Time.utc(2026, 11, 10, 8, 22, 15, 100_000))
    second = create_trace!(duration_nano: 3_000_000, timestamp: Time.utc(2026, 11, 10, 8, 22, 15, 900_000))

    described_class.call(first, definition)
    described_class.call(second, definition)

    rows = described_class.summed_rows(metric_name)
    expect(rows.size).to eq(1)
    expect(rows.first["value_sum"].to_f).to eq(4_000_000.0)
    expect(rows.first["value_count"].to_i).to eq(2)
  end
end
