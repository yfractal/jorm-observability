# frozen_string_literal: true

require "rails_helper"

RSpec.describe TraceToMetrics::Gauge::TableManager, :no_transaction do
  def build_definition(name: "avg_duration_nano_gauge", dimensions: [])
    TraceToMetric.new(
      name: name,
      span_name: TraceToMetric::QUERY_SPAN_NAME,
      metric_type: "gauge",
      dimensions: dimensions
    )
  end

  after { drop_metric_tables("avg_duration_nano_gauge") }

  describe ".create!" do
    it "creates a gauge table with value_sum and value_count" do
      described_class.create!(build_definition)

      expect(Greptime::Connection.table_exists?("avg_duration_nano_gauge")).to eq(true)
      columns = Greptime::Connection.column_names("avg_duration_nano_gauge")
      expect(columns).to include("bucket", "value_sum", "value_count")
      expect(columns).not_to include("value")
    end
  end
end
