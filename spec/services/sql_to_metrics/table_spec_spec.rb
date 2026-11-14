require "rails_helper"

RSpec.describe SqlToMetrics::TableSpec do
  describe ".call" do
    it "captures COUNT(*)" do
      sql = <<~SQL
        SELECT
            date_bin('1 minute', timestamp) AS time,
            COUNT(*) AS count
        FROM opentelemetry_traces
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)
      expect(result[:dimensions]).to eq []
    end

    it 'per service name' do
      sql = <<~SQL
        SELECT
            date_bin('1 minute', timestamp) AS time,
            COUNT(service_name) AS count
        FROM opentelemetry_traces
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)
      expect(result[:dimensions]).to eq []

    end

    it "builds a counter table spec for request_count with minute date_bin and parent_span_id IS NULL" do
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

      expect(result[:name]).to eq("opentelemetry_traces_1_minute_parent_span_id_is_null_counter")
      expect(result[:metric_type]).to eq("counter")
      expect(result[:source_table]).to eq("opentelemetry_traces")
      expect(result[:bucket_interval]).to eq("1 minute")
      expect(result[:bucket_column]).to eq("timestamp")
      expect(result[:dimensions]).to eq([])
      expect(result[:distinct_column]).to be_nil
      expect(result[:filters]).to eq([ { column: "parent_span_id", op: "IS NULL" } ])
      expect(result[:columns]).to eq([
        { name: "bucket", type: "TIMESTAMP", time_index: true },
        { name: "value", type: "BIGINT" }
      ])
      expect(result[:primary_key]).to eq([])
    end

    it "captures COUNT(DISTINCT ...) as distinct_column" do
      sql = <<~SQL
        SELECT
            date_bin('1 minute', timestamp) AS time,
            COUNT(DISTINCT trace_id) AS trace_count
        FROM opentelemetry_traces
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)

      expect(result[:distinct_column]).to eq("trace_id")
      expect(result[:name]).to eq("opentelemetry_traces_1_minute_distinct_trace_id_counter")
      expect(result[:bucket_interval]).to eq("1 minute")
      expect(result[:filters]).to eq([])
      expect(result[:primary_key]).to eq([])
    end

    it "uses a day interval in the name for span_count" do
      sql = <<~SQL
        SELECT
            date_bin('1 day', timestamp) AS time,
            COUNT(*) AS span_count
        FROM opentelemetry_traces
        GROUP BY time
        ORDER BY time;
      SQL

      result = described_class.call(sql)

      expect(result[:bucket_interval]).to eq("1 day")
      expect(result[:name]).to eq("opentelemetry_traces_1_day_counter")
      expect(result[:name]).not_to eq("opentelemetry_traces_1_minute_counter")
    end

    it "allows a bare COUNT(*) with no time bucket" do
      sql = "SELECT COUNT(*) FROM opentelemetry_traces WHERE parent_span_id IS NULL;"

      result = described_class.call(sql)

      expect(result[:bucket_interval]).to be_nil
      expect(result[:bucket_column]).to be_nil
      expect(result[:name]).to eq("opentelemetry_traces_parent_span_id_is_null_counter")
      expect(result[:filters]).to eq([ { column: "parent_span_id", op: "IS NULL" } ])
      expect(result[:columns]).to include(
        { name: "bucket", type: "TIMESTAMP", time_index: true },
        { name: "value", type: "BIGINT" }
      )
    end

    describe "dimensions" do
      it "treats non-time GROUP BY columns as dimensions and primary key" do
        sql = <<~SQL
          SELECT
              date_bin('1 minute', timestamp) AS time,
              service_name,
              COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY service_name, time
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([ "service_name" ])
        expect(result[:primary_key]).to eq([ "service_name" ])
        expect(result[:columns]).to eq([
          { name: "bucket", type: "TIMESTAMP", time_index: true },
          { name: "service_name", type: "STRING" },
          { name: "value", type: "BIGINT" }
        ])
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
        expect(result[:primary_key]).to eq([ "service_name", "span_kind" ])
        expect(result[:columns].map { |c| c[:name] }).to eq(
          %w[bucket service_name span_kind value]
        )
      end

      it "returns dimensions without a time bucket when grouping only by columns" do
        sql = <<~SQL
          SELECT service_name, COUNT(*) AS c
          FROM opentelemetry_traces
          GROUP BY service_name
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([ "service_name" ])
        expect(result[:bucket_interval]).to be_nil
        expect(result[:bucket_column]).to be_nil
        expect(result[:primary_key]).to eq([ "service_name" ])
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
        expect(result[:bucket_interval]).to eq("1 minute")
        expect(result[:bucket_column]).to eq("timestamp")
        expect(result[:primary_key]).to eq([])
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
        expect(result[:primary_key]).to eq([])
      end

      it "uses the bare column name for qualified GROUP BY refs" do
        sql = <<~SQL
          SELECT t.service_name, COUNT(*) AS c
          FROM opentelemetry_traces t
          GROUP BY t.service_name
        SQL

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([ "service_name" ])
        expect(result[:primary_key]).to eq([ "service_name" ])
      end

      it "returns empty dimensions when there is no GROUP BY" do
        sql = "SELECT COUNT(*) FROM opentelemetry_traces"

        result = described_class.call(sql)

        expect(result[:dimensions]).to eq([])
        expect(result[:primary_key]).to eq([])
        expect(result[:name]).to eq("opentelemetry_traces_counter")
      end
    end

    it "includes equality and IS NOT NULL filters in the name" do
      sql = <<~SQL
        SELECT COUNT(*) FROM opentelemetry_traces
        WHERE service_name = 'lobsters' AND parent_span_id IS NOT NULL
      SQL

      result = described_class.call(sql)

      expect(result[:filters]).to contain_exactly(
        { column: "service_name", op: "=", value: "lobsters" },
        { column: "parent_span_id", op: "IS NOT NULL" }
      )
      expect(result[:name]).to eq(
        "opentelemetry_traces_service_name_lobsters_parent_span_id_is_not_null_counter"
      )
    end

    it "excludes time range filters from the derived name" do
      sql = <<~SQL
        SELECT
            date_bin('1 minute', timestamp) AS time,
            COUNT(*) AS c
        FROM opentelemetry_traces
        WHERE parent_span_id IS NULL
          AND timestamp >= '2026-01-01'
          AND timestamp < '2026-01-02'
        GROUP BY time
      SQL

      result = described_class.call(sql)

      expect(result[:name]).to eq("opentelemetry_traces_1_minute_parent_span_id_is_null_counter")
      expect(result[:filters]).to eq([ { column: "parent_span_id", op: "IS NULL" } ])
      expect(result[:time_range][:from][:value][:value]).to eq("2026-01-01")
      expect(result[:time_range][:to][:value][:value]).to eq("2026-01-02")
    end

    it "raises UnsupportedError for unsupported aggs like AVG" do
      sql = "SELECT AVG(duration) AS avg_d FROM opentelemetry_traces"

      expect {
        described_class.call(sql)
      }.to raise_error(SqlToMetrics::UnsupportedError, /counter/)
    end

    it "raises ParseError for invalid SQL" do
      expect {
        described_class.call("SELECT FROM")
      }.to raise_error(SqlToMetrics::ParseError)
    end

    it "raises UnsupportedError for multiple counter aggregates" do
      sql = "SELECT COUNT(*), COUNT(DISTINCT trace_id) FROM opentelemetry_traces"

      expect {
        described_class.call(sql)
      }.to raise_error(SqlToMetrics::UnsupportedError, /exactly one counter/)
    end

    it "matches TableManager column and primary key layout for dimensions" do
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
      definition = TraceToMetric.new(
        span_name: "http",
        metric_type: "counter",
        dimensions: result[:dimensions]
      )

      expect(result[:primary_key]).to eq(definition.dimension_columns)
      expect(result[:columns]).to eq([
        { name: "bucket", type: "TIMESTAMP", time_index: true },
        *definition.dimension_columns.map { |name| { name: name, type: "STRING" } },
        { name: "value", type: "BIGINT" }
      ])
    end
  end
end
