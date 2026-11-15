# frozen_string_literal: true

require "rails_helper"

RSpec.describe SqlToMetrics::Gauge::TableSpec do
  describe ".call" do
    it "builds a gauge table spec for average response" do
      sql = <<~SQL
        SELECT AVG(duration_nano) / 1e6 AS value
        FROM opentelemetry_traces
        WHERE span_kind = 'SPAN_KIND_SERVER'
          AND "span_attributes.http.response.status_code" IS NOT NULL
      SQL

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("gauge")
      expect(result[:value_column]).to eq("duration_nano")
      expect(result[:scale]).to eq(1_000_000.0)
      expect(result[:bucket_interval]).to eq("1 minute")
      expect(result[:time_bucketed]).to eq(false)
      expect(result[:name]).to eq(
        "opentelemetry_traces_span_kind_span_kind_server_" \
        "span_attributes_http_response_status_code_is_not_null_avg_duration_nano_gauge"
      )
      expect(result[:columns]).to eq([
        { name: "bucket", type: "TIMESTAMP", time_index: true },
        { name: "value_sum", type: "DOUBLE" },
        { name: "value_count", type: "BIGINT" }
      ])
    end

    it "shares one 1-minute table across date_bin $per values" do
      sql = <<~SQL
        SELECT date_bin('5 minutes', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
        FROM opentelemetry_traces
        WHERE "span_attributes.db.system" IS NOT NULL
        GROUP BY time
        ORDER BY time
      SQL

      result = described_class.call(sql)

      expect(result[:name]).to eq(
        "opentelemetry_traces_span_attributes_db_system_is_not_null_avg_duration_nano_gauge"
      )
      expect(result[:time_bucketed]).to eq(true)
      expect(result[:bucket_interval]).to eq("1 minute")
      expect(result[:query_interval]).to eq("5 minutes")
    end

    it "uses the same name for bare AVG and every $per" do
      filters_sql = "span_kind = 'SPAN_KIND_SERVER'"
      names = [
        "SELECT AVG(duration_nano) AS value FROM opentelemetry_traces WHERE #{filters_sql}",
        "SELECT date_bin('1 minute', timestamp) AS time, AVG(duration_nano) AS mean FROM opentelemetry_traces WHERE #{filters_sql} GROUP BY time",
        "SELECT date_bin('1 hour', timestamp) AS time, AVG(duration_nano) AS mean FROM opentelemetry_traces WHERE #{filters_sql} GROUP BY time"
      ].map { |sql| described_class.call(sql)[:name] }

      expect(names.uniq).to eq([
        "opentelemetry_traces_span_kind_span_kind_server_avg_duration_nano_gauge"
      ])
    end
  end

  describe ".value_column_from_name" do
    it "parses the avg column from the metric name" do
      expect(
        described_class.value_column_from_name(
          "opentelemetry_traces_1_minute_avg_duration_nano_gauge"
        )
      ).to eq("duration_nano")
    end
  end
end
