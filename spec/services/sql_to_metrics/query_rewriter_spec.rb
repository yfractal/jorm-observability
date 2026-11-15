require "rails_helper"

RSpec.describe SqlToMetrics::QueryRewriter, :no_transaction do
  let(:metric_name) { "opentelemetry_traces_1_minute_counter" }

  def definition(dimensions: [ "scope_name" ])
    Struct.new(:name, :dimensions, keyword_init: true) do
      def dimension_columns
        Array(dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      end
    end.new(name: metric_name, dimensions: dimensions)
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

  def seed_metric_coverage!
    TraceToMetrics::TableManager.create!(definition)
    # buckets 10:00 .. 10:05 — coverage after edge exclusion: [10:01, 10:05)
    (0..5).each do |m|
      insert_metric_row(
        bucket: Time.utc(2026, 1, 1, 10, m, 0),
        scope_name: "web",
        value: 10
      )
    end
  end

  after do
    drop_metric_tables(metric_name)
  end

  describe ".split_ranges" do
    let(:coverage) { { from: Time.utc(2026, 1, 1, 10, 1, 0), to: Time.utc(2026, 1, 1, 10, 5, 0) } }

    it "uses the metric for the overlapping aligned window and raw for edges" do
      query_range = {
        from: { time: Time.utc(2026, 1, 1, 10, 0, 30), inclusive: true },
        to: { time: Time.utc(2026, 1, 1, 10, 5, 45), inclusive: false }
      }

      segments = described_class.split_ranges(query_range, coverage, "1 minute")

      expect(segments[:metric]).to eq(
        from: Time.utc(2026, 1, 1, 10, 1, 0),
        to: Time.utc(2026, 1, 1, 10, 5, 0)
      )
      expect(segments[:raw]).to contain_exactly(
        { from: Time.utc(2026, 1, 1, 10, 0, 30), to: Time.utc(2026, 1, 1, 10, 1, 0) },
        { from: Time.utc(2026, 1, 1, 10, 5, 0), to: Time.utc(2026, 1, 1, 10, 5, 45) }
      )
    end

    it "returns raw only when there is no overlap with coverage" do
      query_range = {
        from: { time: Time.utc(2026, 1, 1, 11, 0, 0), inclusive: true },
        to: { time: Time.utc(2026, 1, 1, 12, 0, 0), inclusive: false }
      }

      segments = described_class.split_ranges(query_range, coverage, "1 minute")

      expect(segments[:metric]).to be_nil
      expect(segments[:raw]).to eq([
        { from: Time.utc(2026, 1, 1, 11, 0, 0), to: Time.utc(2026, 1, 1, 12, 0, 0) }
      ])
    end
  end

  describe ".call" do
    it "returns the original SQL when the metric table is missing" do
      sql = <<~SQL
        SELECT date_bin('1 minute', timestamp) AS time, scope_name, COUNT(*) AS count
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 11:00:00'
        GROUP BY scope_name, time
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(false)
      expect(result.sql).to eq(sql)
    end

    it "rewrites to a UNION ALL when the metric covers part of the range" do
      seed_metric_coverage!

      sql = <<~SQL
        SELECT date_bin('1 minute', timestamp) AS time, scope_name, COUNT(*) AS count
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 10:06:00'
        GROUP BY scope_name, time
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(true)
      expect(result.metric_name).to eq(metric_name)
      expect(result.sql).to include("UNION ALL")
      expect(result.sql).to include(Greptime::Connection.quote_table_name(metric_name))
      expect(result.sql).to include("opentelemetry_traces")
      expect(result.segments[:metric]).to eq(
        from: Time.utc(2026, 1, 1, 10, 1, 0),
        to: Time.utc(2026, 1, 1, 10, 5, 0)
      )
    end

    it "falls back when the query dimension is not on the metric table" do
      TraceToMetrics::TableManager.create!(definition(dimensions: []))
      table = Greptime::Connection.quote_table_name(metric_name)
      [ 0, 1, 2 ].each do |m|
        Greptime::Connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO #{table} (bucket, value) VALUES (?, ?)",
            Time.utc(2026, 1, 1, 10, m, 0),
            1
          ])
        )
      end

      sql = <<~SQL
        SELECT date_bin('1 minute', timestamp) AS time, scope_name, COUNT(*) AS count
        FROM opentelemetry_traces
        WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 11:00:00'
        GROUP BY scope_name, time
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(false)
      expect(result.sql).to eq(sql)
    end

    it "rewrites a bare COUNT(*) into SUM(value) when the metric has coverage" do
      bare_name = "opentelemetry_traces_parent_span_id_is_null_counter"
      drop_metric_tables(bare_name)
      TraceToMetrics::TableManager.create!(
        Struct.new(:name, :dimensions, keyword_init: true) do
          def dimension_columns
            []
          end
        end.new(name: bare_name, dimensions: [])
      )
      table = Greptime::Connection.quote_table_name(bare_name)
      (0..5).each do |m|
        Greptime::Connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO #{table} (bucket, value) VALUES (?, ?)",
            Time.utc(2026, 1, 1, 10, m, 0),
            10
          ])
        )
      end

      sql = <<~SQL
        SELECT COUNT(*) AS value
        FROM opentelemetry_traces
        WHERE parent_span_id IS NULL
          AND timestamp >= '2026-01-01 10:00:00'
          AND timestamp < '2026-01-01 10:06:00'
      SQL

      result = described_class.call(sql)

      expect(result.used_metric).to eq(true)
      expect(result.metric_name).to eq(bare_name)
      expect(result.sql).to start_with("SELECT SUM(value) AS \"value\"")
      expect(result.sql).to include(table)
      expect(result.sql).to include("UNION ALL")
      expect(result.segments[:metric]).to eq(
        from: Time.utc(2026, 1, 1, 10, 1, 0),
        to: Time.utc(2026, 1, 1, 10, 5, 0)
      )
    ensure
      drop_metric_tables(bare_name)
    end
  end
end
