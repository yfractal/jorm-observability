require "rails_helper"

RSpec.describe TraceToMetrics::TableManager, :no_transaction do
  def build_definition(name: "http_counter", dimensions: [ "http.method" ])
    TraceToMetric.new(
      name: name,
      span_name: name.delete_suffix("_counter"),
      metric_type: "counter",
      dimensions: dimensions
    )
  end

  after do
    drop_metric_tables("http_counter", "redis_counter")
  end

  describe ".create!" do
    it "creates a metric table with bucket, dimensions, and value" do
      definition = build_definition(dimensions: [ "http.method", "http.route" ])

      described_class.create!(definition)

      expect(Greptime::Connection.table_exists?("http_counter")).to eq(true)

      columns = Greptime::Connection.column_names("http_counter")
      expect(columns).to include("bucket", "http_method", "http_route", "value")
      expect(columns).not_to include("created_at", "updated_at")
    end

    it "raises when the table already exists" do
      definition = build_definition
      described_class.create!(definition)

      expect {
        described_class.create!(definition)
      }.to raise_error(TraceToMetrics::TableManager::Error, /already exists/)
    end

    it "raises for reserved table names" do
      definition = build_definition(name: "opentelemetry_traces", dimensions: [])
      definition.define_singleton_method(:name) { "opentelemetry_traces" }

      expect {
        described_class.create!(definition)
      }.to raise_error(TraceToMetrics::TableManager::Error, /reserved/)
    end
  end

  describe ".add_dimensions!" do
    it "adds columns for new dimensions" do
      definition = build_definition(dimensions: [ "http.method" ])
      described_class.create!(definition)

      definition.dimensions = [ "http.method", "http.route" ]
      described_class.add_dimensions!(definition, [ "http.route" ])

      columns = Greptime::Connection.column_names("http_counter")
      expect(columns).to include("http_route")
    end
  end
end
