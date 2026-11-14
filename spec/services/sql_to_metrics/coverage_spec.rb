require "rails_helper"

RSpec.describe SqlToMetrics::Coverage, :no_transaction do
  let(:metric_name) { "coverage_test_1_minute_counter" }
  let(:interval) { "1 minute" }

  def definition
    Struct.new(:name, :dimensions, keyword_init: true) do
      def dimension_columns
        Array(dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      end
    end.new(name: metric_name, dimensions: [ "scope_name" ])
  end

  def insert_metric_row(bucket:, scope_name:, value: 1)
    table = Greptime::Connection.quote_table_name(metric_name)
    Greptime::Connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([
        "INSERT INTO #{table} (bucket, scope_name, value) VALUES (?, ?, ?)",
        bucket,
        scope_name,
        value
      ])
    )
  end

  after do
    drop_metric_tables(metric_name)
  end

  it "returns nil when the metric table does not exist" do
    expect(described_class.call("missing_metric_table", bucket_interval: interval)).to be_nil
  end

  it "returns nil when the metric table is empty" do
    TraceToMetrics::TableManager.create!(definition)
    expect(described_class.call(metric_name, bucket_interval: interval)).to be_nil
  end

  it "returns nil when only one bucket exists (both edges excluded)" do
    TraceToMetrics::TableManager.create!(definition)
    insert_metric_row(bucket: Time.utc(2026, 1, 1, 10, 0, 0), scope_name: "a")

    expect(described_class.call(metric_name, bucket_interval: interval)).to be_nil
  end

  it "excludes the first and last buckets from coverage" do
    TraceToMetrics::TableManager.create!(definition)
    insert_metric_row(bucket: Time.utc(2026, 1, 1, 10, 0, 0), scope_name: "a")
    insert_metric_row(bucket: Time.utc(2026, 1, 1, 10, 1, 0), scope_name: "a")
    insert_metric_row(bucket: Time.utc(2026, 1, 1, 10, 2, 0), scope_name: "a")
    insert_metric_row(bucket: Time.utc(2026, 1, 1, 10, 3, 0), scope_name: "a")

    coverage = described_class.call(metric_name, bucket_interval: interval)

    expect(coverage[:from]).to eq(Time.utc(2026, 1, 1, 10, 1, 0))
    expect(coverage[:to]).to eq(Time.utc(2026, 1, 1, 10, 3, 0))
  end
end
