# frozen_string_literal: true

require "rails_helper"

RSpec.describe SqlToMetrics::QueryKind do
  it "detects histogram SQL" do
    sql = "SELECT approx_percentile_cont(duration_nano, 0.99) FROM opentelemetry_traces"
    expect(described_class.call(sql)).to eq(:histogram)
  end

  it "detects gauge SQL" do
    sql = "SELECT AVG(duration_nano) FROM opentelemetry_traces WHERE span_kind = 'SPAN_KIND_SERVER'"
    expect(described_class.call(sql)).to eq(:gauge)
  end

  it "defaults to counter" do
    sql = "SELECT COUNT(*) FROM opentelemetry_traces WHERE parent_span_id IS NULL"
    expect(described_class.call(sql)).to eq(:counter)
  end
end
