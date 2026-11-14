require "rails_helper"

RSpec.describe SqlToMetrics::Runner, :no_transaction do
  let(:metric_name) { "opentelemetry_traces_1_minute_counter" }

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

  def backfill_metric_from_traces!
    sql = <<~SQL
      SELECT
        date_bin('1 minute', timestamp) AS time,
        scope_name,
        COUNT(*) AS count
      FROM opentelemetry_traces
      GROUP BY scope_name, time
    SQL

    spec = SqlToMetrics::TableSpec.call(sql)
    dimensions = Array(spec[:primary_key])
    definition = Struct.new(:name, :dimensions, keyword_init: true) do
      def dimension_columns
        Array(dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      end
    end.new(name: spec[:name], dimensions: spec[:dimensions])

    if Greptime::Connection.table_exists?(spec[:name])
      Greptime::Connection.truncate_table(spec[:name])
    else
      TraceToMetrics::TableManager.create!(definition)
    end

    table = Greptime::Connection.quote_table_name(spec[:name])
    source = Greptime::Connection.quote_table_name(spec[:source_table])
    bucket_column = Greptime::Connection.quote_column_name(spec[:bucket_column])
    select_dims = dimensions.map { |c| Greptime::Connection.quote_column_name(c) }
    insert_cols = [ "bucket", *dimensions, "value" ].map { |c|
      Greptime::Connection.quote_column_name(c)
    }
    select_list = [
      "date_bin('#{spec[:bucket_interval]}', #{bucket_column}) AS bucket",
      *select_dims,
      "COUNT(*) AS value"
    ].join(", ")

    Greptime::Connection.execute(<<~SQL.squish)
      INSERT INTO #{table} (#{insert_cols.join(', ')})
      SELECT #{select_list}
      FROM #{source}
      GROUP BY bucket, #{select_dims.join(', ')}
    SQL

    spec[:name]
  end

  def query_sql(from:, to:)
    <<~SQL
      SELECT
        date_bin('1 minute', timestamp) AS time,
        scope_name,
        COUNT(*) AS count
      FROM opentelemetry_traces
      WHERE timestamp >= '#{from}'
        AND timestamp < '#{to}'
      GROUP BY scope_name, time
      ORDER BY time, scope_name
    SQL
  end

  def normalize(rows)
    rows.map { |r|
      {
        time: Time.parse(r["time"].to_s).utc,
        scope_name: r["scope_name"],
        count: r["count"].to_i
      }
    }.sort_by { |r| [ r[:time], r[:scope_name] ] }
  end

  before do
    drop_metric_tables(metric_name)
  end

  after do
    drop_metric_tables(metric_name)
  end

  it "falls back to the raw query when no metric exists" do
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 2, 15), scope_name: "web")
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 2, 45), scope_name: "web")

    sql = query_sql(from: "2026-01-01 10:00:00", to: "2026-01-01 10:06:00")
    result = described_class.call(sql)

    expect(result.used_metric).to eq(false)
    expect(normalize(result.rows)).to eq([
      { time: Time.utc(2026, 1, 1, 10, 2, 0), scope_name: "web", count: 2 }
    ])
  end

  it "creates traces, backfills metrics, runs a hybrid query, and matches raw results" do
    # Traces that will be backfilled into the metric (10:00 .. 10:05)
    {
      Time.utc(2026, 1, 1, 10, 0, 10) => "web",
      Time.utc(2026, 1, 1, 10, 0, 40) => "web",
      Time.utc(2026, 1, 1, 10, 1, 10) => "web",
      Time.utc(2026, 1, 1, 10, 1, 20) => "api",
      Time.utc(2026, 1, 1, 10, 1, 40) => "web",
      Time.utc(2026, 1, 1, 10, 2, 10) => "api",
      Time.utc(2026, 1, 1, 10, 2, 40) => "api",
      Time.utc(2026, 1, 1, 10, 3, 10) => "web",
      Time.utc(2026, 1, 1, 10, 3, 40) => "web",
      Time.utc(2026, 1, 1, 10, 4, 10) => "web",
      Time.utc(2026, 1, 1, 10, 4, 40) => "api",
      Time.utc(2026, 1, 1, 10, 5, 10) => "web",
      Time.utc(2026, 1, 1, 10, 5, 40) => "web"
    }.each { |ts, scope| create_trace!(timestamp: ts, scope_name: scope) }

    name = backfill_metric_from_traces!
    expect(name).to eq(metric_name)
    expect(Greptime::Connection.table_exists?(metric_name)).to eq(true)

    # Traces after backfill — only available from raw (extends past metric MAX bucket)
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 6, 15), scope_name: "web")
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 6, 45), scope_name: "api")
    create_trace!(timestamp: Time.utc(2026, 1, 1, 10, 7, 10), scope_name: "web")

    sql = query_sql(from: "2026-01-01 10:00:00", to: "2026-01-01 10:08:00")
    raw_rows = Greptime::Connection.exec_query(sql).to_a
    result = described_class.call(sql)

    expect(result.used_metric).to eq(true)
    expect(result.metric_name).to eq(metric_name)
    expect(result.sql).to include("UNION ALL")
    expect(result.sql).to include(Greptime::Connection.quote_table_name(metric_name))
    expect(result.sql).to include("opentelemetry_traces")

    # Coverage excludes first/last backfilled buckets: [10:01, 10:05)
    expect(result.segments[:metric]).to eq(
      from: Time.utc(2026, 1, 1, 10, 1, 0),
      to: Time.utc(2026, 1, 1, 10, 5, 0)
    )
    expect(result.segments[:raw]).to contain_exactly(
      { from: Time.utc(2026, 1, 1, 10, 0, 0), to: Time.utc(2026, 1, 1, 10, 1, 0) },
      { from: Time.utc(2026, 1, 1, 10, 5, 0), to: Time.utc(2026, 1, 1, 10, 8, 0) }
    )

    expect(normalize(result.rows)).to eq(normalize(raw_rows))
    expect(normalize(result.rows)).to eq([
      { time: Time.utc(2026, 1, 1, 10, 0, 0), scope_name: "web", count: 2 },
      { time: Time.utc(2026, 1, 1, 10, 1, 0), scope_name: "api", count: 1 },
      { time: Time.utc(2026, 1, 1, 10, 1, 0), scope_name: "web", count: 2 },
      { time: Time.utc(2026, 1, 1, 10, 2, 0), scope_name: "api", count: 2 },
      { time: Time.utc(2026, 1, 1, 10, 3, 0), scope_name: "web", count: 2 },
      { time: Time.utc(2026, 1, 1, 10, 4, 0), scope_name: "api", count: 1 },
      { time: Time.utc(2026, 1, 1, 10, 4, 0), scope_name: "web", count: 1 },
      { time: Time.utc(2026, 1, 1, 10, 5, 0), scope_name: "web", count: 2 },
      { time: Time.utc(2026, 1, 1, 10, 6, 0), scope_name: "api", count: 1 },
      { time: Time.utc(2026, 1, 1, 10, 6, 0), scope_name: "web", count: 1 },
      { time: Time.utc(2026, 1, 1, 10, 7, 0), scope_name: "web", count: 1 }
    ])
  end
end
