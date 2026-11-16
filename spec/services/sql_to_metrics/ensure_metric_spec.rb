# frozen_string_literal: true

require "rails_helper"

RSpec.describe SqlToMetrics::EnsureMetric do
  it "routes COUNT SQL to CounterMetrics::EnsureMetric" do
    sql = "SELECT COUNT(*) FROM opentelemetry_traces"
    expect(CounterMetrics::EnsureMetric).to receive(:new).with(sql).and_return(instance_double(CounterMetrics::EnsureMetric, call: :ok))
    expect(described_class.new(sql).call).to eq(:ok)
  end

  it "routes AVG SQL to GaugeMetrics::EnsureMetric" do
    sql = "SELECT AVG(duration_nano) FROM opentelemetry_traces"
    expect(GaugeMetrics::EnsureMetric).to receive(:new).with(sql).and_return(instance_double(GaugeMetrics::EnsureMetric, call: :ok))
    expect(described_class.new(sql).call).to eq(:ok)
  end

  it "routes percentile SQL to HistogramMetrics::EnsureMetric" do
    sql = "SELECT approx_percentile_cont(duration_nano, 0.99) FROM opentelemetry_traces"
    expect(HistogramMetrics::EnsureMetric).to receive(:new).with(sql).and_return(instance_double(HistogramMetrics::EnsureMetric, call: :ok))
    expect(described_class.new(sql).call).to eq(:ok)
  end
end
