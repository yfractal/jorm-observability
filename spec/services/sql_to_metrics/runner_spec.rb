require "rails_helper"

RSpec.describe SqlToMetrics::Runner, :no_transaction do
  let(:metric_name) { "opentelemetry_traces_1_minute_counter" }

  def definition
    Struct.new(:name, :dimensions, keyword_init: true) do
      def dimension_columns
        Array(dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      end
    end.new(name: metric_name, dimensions: [ "scope_name" ])
  end

  def create_trace!(timestamp:, scope_name:)
    OpentelemetryTrace.create!(
      timestamp: timestamp,
      span_name: "http",
      trace_id: SecureRandom.hex(16),
      span_id: SecureRandom.hex(8),
      service_name: "lobsters",
      span_kind: "SERVER",
      span_status_code: "OK",
      scope_name: scope_name,
      span_attributes: {},
      resource_attributes: {}
    )
  end

  def insert_metric_row(bucket:, scope_name:, value:)
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

  def query_sql
    <<~SQL
      SELECT
        date_bin('1 minute', timestamp) AS time,
        scope_name,
        COUNT(*) AS count
      FROM opentelemetry_traces
      WHERE timestamp >= '2026-01-01 10:00:00'
        AND timestamp < '2026-01-01 10:06:00'
      GROUP BY scope_name, time
      ORDER BY time
    SQL
  end

  after do
    drop_metric_tables(metric_name)
  end

  it "falls back to the raw query when no metric exists" do
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 2, 15), scope_name: "web")
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 2, 45), scope_name: "web")

    result = described_class.call(query_sql)

    expect(result.used_metric).to eq(false)
    expect(result.rows.size).to eq(1)
    expect(result.rows.first["count"].to_i).to eq(2)
    expect(result.rows.first["scope_name"]).to eq("web")
  end

  it "matches a pure-raw query when combining metric and raw segments" do
    # Raw traces across the full window
    [
      Time.utc(2026, 1, 1, 10, 0, 10), # raw edge (before coverage)
      Time.utc(2026, 1, 1, 10, 0, 40),
      Time.utc(2026, 1, 1, 10, 1, 10), # covered by metric if we seed matching counts
      Time.utc(2026, 1, 1, 10, 1, 40),
      Time.utc(2026, 1, 1, 10, 2, 10),
      Time.utc(2026, 1, 1, 10, 2, 40),
      Time.utc(2026, 1, 1, 10, 3, 10),
      Time.utc(2026, 1, 1, 10, 3, 40),
      Time.utc(2026, 1, 1, 10, 4, 10),
      Time.utc(2026, 1, 1, 10, 4, 40),
      Time.utc(2026, 1, 1, 10, 5, 10), # raw edge (last bucket excluded from coverage)
      Time.utc(2026, 1, 1, 10, 5, 40)
    ].each { |ts| create_trace!(timestamp: ts, scope_name: "web") }

    # Metric table covering 10:00..10:05 with correct per-minute counts (2 each)
    TraceToMetrics::TableManager.create!(definition)
    (0..5).each do |m|
      insert_metric_row(
        bucket: Time.utc(2026, 1, 1, 10, m, 0),
        scope_name: "web",
        value: 2
      )
    end

    raw_rows = Greptime::Connection.exec_query(query_sql).to_a
    result = described_class.call(query_sql)

    expect(result.used_metric).to eq(true)
    expect(result.sql).to include("UNION ALL")

    normalize = ->(rows) {
      rows.map { |r|
        {
          time: Time.parse(r["time"].to_s).utc,
          scope_name: r["scope_name"],
          count: r["count"].to_i
        }
      }.sort_by { |r| [ r[:time], r[:scope_name] ] }
    }

    expect(normalize.call(result.rows)).to eq(normalize.call(raw_rows))
  end
end
