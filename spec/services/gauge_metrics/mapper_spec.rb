# frozen_string_literal: true

require "rails_helper"

RSpec.describe GaugeMetrics::Mapper do
  describe ".call" do
    it "maps bare AVG(col) / scale" do
      sql = <<~SQL
        SELECT AVG(duration_nano) / 1e6 AS value
        FROM opentelemetry_traces
        WHERE span_kind = 'SPAN_KIND_SERVER'
          AND "span_attributes.http.response.status_code" IS NOT NULL
      SQL

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("gauge")
      expect(result[:time_bucket]).to be_nil
      expect(result[:res_targets]).to eq([
        {
          alias: "value",
          kind: :agg,
          func: "avg",
          column: "duration_nano",
          scale: 1_000_000.0,
          distinct: false,
          args: [ "duration_nano" ]
        }
      ])
      expect(result[:filters]).to contain_exactly(
        { column: "span_kind", op: "=", value: "SPAN_KIND_SERVER" },
        { column: "span_attributes.http.response.status_code", op: "IS NOT NULL" }
      )
    end

    it "maps date_bin + AVG mean series" do
      sql = <<~SQL
        SELECT date_bin('1 minute', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
        FROM opentelemetry_traces
        WHERE scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
        GROUP BY time
        ORDER BY time
      SQL

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("gauge")
      expect(result[:time_bucket]).to eq(
        interval: "1 minute",
        column: "timestamp",
        alias: "time"
      )
      expect(result[:res_targets]).to include(
        hash_including(
          alias: "mean",
          kind: :agg,
          func: "avg",
          column: "duration_nano",
          scale: 1_000_000.0
        )
      )
      expect(result[:filters]).to eq([
        { column: "scope_name", op: "=", value: "OpenTelemetry::Instrumentation::ActiveJob" }
      ])
    end

    it "maps AVG without scale" do
      sql = "SELECT AVG(duration_nano) AS value FROM opentelemetry_traces"

      result = described_class.call(sql)

      expect(result[:res_targets].first[:scale]).to be_nil
      expect(result[:res_targets].first[:column]).to eq("duration_nano")
    end
  end
end
