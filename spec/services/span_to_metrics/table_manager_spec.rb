require "rails_helper"

RSpec.describe SpanToMetrics::TableManager, :no_transaction do
  def build_definition(name: "http_counter", dimensions: [ "http.method" ])
    SpanToMetric.new(
      name: name,
      span_name: name.delete_suffix("_counter"),
      metric_type: "counter",
      dimensions: dimensions
    )
  end

  after do
    conn = ActiveRecord::Base.connection
    conn.drop_table("http_counter", if_exists: true)
    conn.drop_table("redis_counter", if_exists: true)
  end

  describe ".create!" do
    it "creates a metric table with bucket, dimensions, and value" do
      definition = build_definition(dimensions: [ "http.method", "http.route" ])

      described_class.create!(definition)

      conn = ActiveRecord::Base.connection
      expect(conn.table_exists?("http_counter")).to eq(true)

      columns = conn.columns("http_counter").map(&:name)
      expect(columns).to include("bucket", "http_method", "http_route", "value", "created_at", "updated_at")

      index = conn.indexes("http_counter").find { |i| i.name == "index_http_counter_on_bucket_dimensions" }
      expect(index).to be_present
      expect(index.unique).to eq(true)
      expect(index.columns).to eq(%w[bucket http_method http_route])
    end

    it "raises when the table already exists" do
      definition = build_definition
      described_class.create!(definition)

      expect {
        described_class.create!(definition)
      }.to raise_error(SpanToMetrics::TableManager::Error, /already exists/)
    end

    it "raises for reserved table names" do
      definition = build_definition(name: "spans", dimensions: [])
      definition.define_singleton_method(:name) { "spans" }

      expect {
        described_class.create!(definition)
      }.to raise_error(SpanToMetrics::TableManager::Error, /reserved/)
    end
  end

  describe ".add_dimensions!" do
    it "adds columns and rebuilds the unique index" do
      definition = build_definition(dimensions: [ "http.method" ])
      described_class.create!(definition)

      definition.dimensions = [ "http.method", "http.route" ]
      described_class.add_dimensions!(definition, [ "http.route" ])

      conn = ActiveRecord::Base.connection
      columns = conn.columns("http_counter").map(&:name)
      expect(columns).to include("http_route")

      index = conn.indexes("http_counter").find { |i| i.name == "index_http_counter_on_bucket_dimensions" }
      expect(index.columns).to eq(%w[bucket http_method http_route])
    end
  end
end
