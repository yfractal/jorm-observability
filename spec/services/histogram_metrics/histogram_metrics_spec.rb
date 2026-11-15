require "rails_helper"

RSpec.describe HistogramMetrics, :no_transaction do
  let(:sql) do
    <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time,
             approx_percentile_cont(duration_nano, 0.99) / 1e6 AS p99
      FROM opentelemetry_traces
      WHERE timestamp >= '2026-01-01 10:00:00' AND timestamp < '2026-01-01 11:00:00'
        AND scope_name = 'db'
      GROUP BY time ORDER BY time
    SQL
  end
  let(:metric_name) { HistogramMetrics::Spec.call(sql)[:name] }

  after { drop_metric_tables(metric_name) }

  def create_trace!(timestamp, duration_ms)
    OpentelemetryTrace.create!(
      timestamp: timestamp, duration_nano: duration_ms * 1_000_000, span_name: "q",
      trace_id: SecureRandom.hex(16), span_id: SecureRandom.hex(8), service_name: "svc",
      scope_name: "db", span_attributes: {}, resource_attributes: {}
    )
  end

  it "detects histogram queries" do
    expect(described_class.histogram_sql?(sql)).to eq(true)
    expect(described_class.histogram_sql?("SELECT COUNT(*) FROM opentelemetry_traces")).to eq(false)
    expect(described_class.histogram_sql?("not sql")).to eq(false)
  end

  it "derives one metric for every quantile and $per" do
    p50 = sql.sub("0.99", "0.50").sub("p99", "p50")
    per_5 = sql.sub("1 minute", "5 minutes")
    expect(HistogramMetrics::Spec.call(p50)[:name]).to eq(metric_name)
    expect(HistogramMetrics::Spec.call(per_5)[:name]).to eq(metric_name)
    expect(metric_name).to eq("opentelemetry_traces_scope_name_db_duration_nano_histogram")
    expect(HistogramMetrics::Spec.call(sql)[:bucket_interval]).to eq("1 minute")
    expect(HistogramMetrics::Spec.call(per_5)[:query_interval]).to eq("5 minutes")
    expect(HistogramMetrics::Spec.call(sql)[:outputs].last[:sql])
      .to eq("uddsketch_calc(0.99, uddsketch_merge(128, 0.01, sketch)) / 1e6")
  end

  it "rejects queries without a constant quantile" do
    bad = sql.sub("0.99", "duration_nano")
    expect { HistogramMetrics::Spec.call(bad) }.to raise_error(SqlToMetrics::UnsupportedError)
  end

  it "backfills, merges live spans, and serves the query from the metric" do
    t0 = Time.utc(2026, 1, 1, 10, 0, 0)
    (1..100).each { |i| create_trace!(t0 + i % 50, i) }

    SqlToMetrics::EnsureMetric.call(sql)
    TraceToMetrics::BackfillJob.new.perform(metric_name)
    expect(TraceToMetric.find(metric_name).metric_type).to eq("histogram")

    # live spans after the watermark, same bucket
    5.times do
      live = create_trace!(t0 + 55, 5000)
      OpentelemetryTraceCreatedJob.new.perform(live.trace_id, live.span_id)
    end

    result = SqlToMetrics::HybridQuery.call(sql)
    expect(result.used_metric).to eq(true)
    expect(result.metric_name).to eq(metric_name)

    raw = SqlToMetrics::HybridQuery.call(sql, use_metric: false).rows
    expect(result.rows.size).to eq(raw.size)
    result.rows.zip(raw).each do |got, want|
      expect(got["time"]).to eq(want["time"])
      expect(got["p99"]).to be_within(want["p99"] * 0.05 + 0.5).of(want["p99"])
    end

    five = SqlToMetrics::HybridQuery.call(sql.sub("1 minute", "5 minutes"))
    expect(five.used_metric).to eq(true)
    expect(five.metric_name).to eq(metric_name)
    expect(five.sql).to include("date_bin('5 minutes', bucket)")
  end
end
