require "rails_helper"

RSpec.describe SqlToMetrics::Mapper do
  describe ".call" do
    it "maps request_count with minute date_bin and parent_span_id IS NULL" do
      sql = <<~SQL
        SELECT
            date_bin('1 minute', timestamp) AS time,
            COUNT(*) AS request_count
        FROM opentelemetry_traces
        WHERE parent_span_id IS NULL
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("counter")
      expect(result[:dimensions]).to eq([])
      expect(result[:source_table]).to eq("opentelemetry_traces")
      expect(result[:time_bucket]).to eq(
        interval: "1 minute",
        column: "timestamp",
        alias: "time"
      )
      expect(result[:res_targets]).to eq([
        { alias: "time", kind: :time_bucket, interval: "1 minute", column: "timestamp" },
        { alias: "request_count", kind: :agg, func: "count", distinct: false, args: [ "*" ] }
      ])
      expect(result[:filters]).to eq([ { column: "parent_span_id", op: "IS NULL" } ])
    end

    it "maps COUNT(DISTINCT ...) as a counter agg" do
      sql = <<~SQL
        SELECT
            date_bin('1 minute', timestamp) AS time,
            COUNT(DISTINCT trace_id) AS trace_count
        FROM opentelemetry_traces
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("counter")
      expect(result[:dimensions]).to eq([])
      expect(result[:time_bucket]).to eq(
        interval: "1 minute",
        column: "timestamp",
        alias: "time"
      )
      expect(result[:res_targets]).to include(
        { alias: "trace_count", kind: :agg, func: "count", distinct: true, args: [ "trace_id" ] }
      )
      expect(result[:filters]).to eq([])
    end

    it "maps span_count with a day date_bin" do
      sql = <<~SQL
        SELECT
            date_bin('1 day', timestamp) AS time,
            COUNT(*) AS span_count
        FROM opentelemetry_traces
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("counter")
      expect(result[:dimensions]).to eq([])
      expect(result[:time_bucket][:interval]).to eq("1 day")
      expect(result[:res_targets]).to include(
        { alias: "span_count", kind: :agg, func: "count", distinct: false, args: [ "*" ] }
      )
    end

    it "maps a bare COUNT(*) with no time bucket" do
      sql = "SELECT COUNT(*) FROM opentelemetry_traces WHERE parent_span_id IS NULL;"

      result = described_class.call(sql)

      expect(result[:metric_type]).to eq("counter")
      expect(result[:dimensions]).to eq([])
      expect(result[:time_bucket]).to be_nil
      expect(result[:res_targets]).to eq([
        { alias: nil, kind: :agg, func: "count", distinct: false, args: [ "*" ] }
      ])
      expect(result[:filters]).to eq([ { column: "parent_span_id", op: "IS NULL" } ])
    end

    describe "dimensions" do
      it "treats non-time GROUP BY columns as dimensions" do
        sql = <<~SQL
          SELECT
              date_bin('1 minute', timestamp) AS time,
              service_name,
              COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY service_name, time
        SQL

        result = described_class.call(sql)

        expect(result[:metric_type]).to eq("counter")
        expect(result[:dimensions]).to eq([ "service_name" ])
        expect(result[:res_targets]).to include(
          hash_including(alias: "service_name", kind: :other)
        )
      end

      it "keeps multiple non-time GROUP BY columns in order" do
        sql = <<~SQL
          SELECT
              date_bin('1 minute', timestamp) AS time,
              service_name,
              span_kind,
              COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY service_name, span_kind, time
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([ "service_name", "span_kind" ])
        expect(result[:time_bucket][:alias]).to eq("time")
      end

      it "returns dimensions without a time bucket when grouping only by columns" do
        sql = <<~SQL
          SELECT service_name, COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY service_name
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([ "service_name" ])
        expect(result[:time_bucket]).to be_nil
      end

      it "excludes an inline date_bin GROUP BY expression from dimensions" do
        sql = <<~SQL
          SELECT
              date_bin('1 minute', timestamp),
              COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY date_bin('1 minute', timestamp)
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([])
        expect(result[:time_bucket]).to eq(
          interval: "1 minute",
          column: "timestamp",
          alias: nil
        )
      end

      it "returns no dimensions when grouping only by the time alias" do
        sql = <<~SQL
          SELECT
              date_bin('1 minute', timestamp) AS time,
              COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY time
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([])
      end

      it "uses the bare column name for qualified GROUP BY refs" do
        sql = <<~SQL
          SELECT t.service_name, COUNT(*) AS c
          FROM opentelemetry_traces t
          GROUP BY t.service_name
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([ "service_name" ])
      end

      it "returns empty dimensions when there is no GROUP BY" do
        sql = "SELECT COUNT(*) FROM opentelemetry_traces"

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([])
      end
    end

    it "returns nil metric_type for unsupported aggs like AVG" do
      sql = "SELECT AVG(duration) AS avg_d FROM opentelemetry_traces"

      result = described_class.call(sql)

      expect(result[:metric_type]).to be_nil
      expect(result[:res_targets]).to eq([
        { alias: "avg_d", kind: :other, expr: "avg(duration)" }
      ])
    end

    it "extracts simple equality and IS NOT NULL filters" do
      sql = <<~SQL
        SELECT COUNT(*) FROM opentelemetry_traces
        WHERE service_name = 'lobsters' AND parent_span_id IS NOT NULL
      SQL

      result = described_class.call(sql)

      expect(result[:filters]).to contain_exactly(
        { column: "service_name", op: "=", value: "lobsters" },
        { column: "parent_span_id", op: "IS NOT NULL" }
      )
    end

    it "raises ParseError for invalid SQL" do
      expect {
        described_class.call("SELECT FROM")
      }.to raise_error(SqlToMetrics::ParseError)
    end
  end
end
