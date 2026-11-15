# frozen_string_literal: true

require "rails_helper"

RSpec.describe SqlToMetrics::Gauge::QueryRewriter, :no_transaction do
  let(:metric_name) {
    "opentelemetry_traces_span_kind_span_kind_server_" \
      "span_attributes_http_response_status_code_is_not_null_avg_duration_nano_gauge"
  }

  def definition
    Struct.new(:name, :dimensions, :metric_type, keyword_init: true) do
      def dimension_columns
        Array(dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      end
    end.new(name: metric_name, dimensions: [], metric_type: "gauge")
  end

  def insert_metric_row(bucket:, value_sum:, value_count:)
    table = Greptime::Connection.quote_table_name(metric_name)
    Greptime::Connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([
        "INSERT INTO #{table} (bucket, value_sum, value_count) VALUES (?, ?, ?)",
        bucket,
        value_sum,
        value_count
      ])
    )
  end

  def seed_metric_coverage!
    TraceToMetrics::Gauge::TableManager.create!(definition)
    (0..5).each do |m|
      insert_metric_row(
        bucket: Time.utc(2026, 1, 1, 10, m, 0),
        value_sum: 10_000_000.0 * (m + 1),
        value_count: m + 1
      )
    end
  end

  after do
    drop_metric_tables(metric_name)
  end

  describe ".call" do
    it "returns the original SQL when the metric table is missing" do
      sql = <<~SQL
        SELECT date_bin('1 minute', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 11:00:00'
          AND span_kind = 'SPAN_KIND_SERVER'
          AND "span_attributes.http.response.status_code" IS NOT NULL
        GROUP BY time
        ORDER BY time
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(false)
      expect(result.sql).to eq(sql)
    end

    it "rewrites to the gauge metric table when coverage exists" do
      seed_metric_coverage!

      sql = <<~SQL
        SELECT date_bin('1 minute', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 10:06:00'
          AND span_kind = 'SPAN_KIND_SERVER'
          AND "span_attributes.http.response.status_code" IS NOT NULL
        GROUP BY time
        ORDER BY time
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(true)
      expect(result.metric_name).to eq(metric_name)
      expect(result.sql).to include("value_sum")
      expect(result.sql).to include("value_count")
      expect(result.sql).to include("/ 1000000.0")
      expect(result.sql).not_to include("UNION ALL")
    end

    it "rewrites bare AVG to a single mean expression" do
      seed_metric_coverage!

      sql = <<~SQL
        SELECT AVG(duration_nano) / 1e6 AS value
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 10:06:00'
          AND span_kind = 'SPAN_KIND_SERVER'
          AND "span_attributes.http.response.status_code" IS NOT NULL
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(true)
      expect(result.metric_name).to eq(metric_name)
      expect(result.sql).to include("SUM(value_sum) / NULLIF(SUM(value_count), 0)")
      expect(result.sql).not_to match(/date_bin\(/)
    end

    it "re-bins a coarser $per from the shared 1-minute table" do
      seed_metric_coverage!

      sql = <<~SQL
        SELECT date_bin('5 minutes', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 10:06:00'
          AND span_kind = 'SPAN_KIND_SERVER'
          AND "span_attributes.http.response.status_code" IS NOT NULL
        GROUP BY time
        ORDER BY time
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(true)
      expect(result.metric_name).to eq(metric_name)
      expect(result.sql).to include("date_bin('5 minutes', bucket)")
      expect(result.sql).not_to include("date_bin('1 minute', bucket)")
    end
  end
end
