require "rails_helper"

RSpec.describe OpentelemetryTraceCreatedJob, type: :job do
  def create_trace!(name: "http", trace_id: "abc", span_id: "def")
    OpentelemetryTrace.create!(
      timestamp: Time.current,
      span_name: name,
      trace_id: trace_id,
      span_id: span_id
    )
  end

  it "returns when the trace is missing" do
    expect(TraceToMetrics::Injector).not_to receive(:call)
    described_class.new.perform("missing", "missing")
  end

  it "skips injection when no TraceToMetric matches the span_name" do
    trace = create_trace!(name: "http")

    expect(TraceToMetrics::Injector).not_to receive(:call)
    described_class.new.perform(trace.trace_id, trace.span_id)
  end

  it "calls Injector when a TraceToMetric matches", :no_transaction do
    definition = TraceToMetric.create!(
      span_name: "http",
      metric_type: "counter",
      dimensions: [ "http.method" ]
    )
    trace = create_trace!(name: "http")

    expect(TraceToMetrics::Injector).to receive(:call).with(trace, definition)
    described_class.new.perform(trace.trace_id, trace.span_id)
  end

  it "increments the metric table end-to-end", :no_transaction do
    TraceToMetric.create!(
      span_name: "http",
      metric_type: "counter",
      dimensions: [ "http.request.method" ]
    )
    timestamp = Time.utc(2026, 11, 10, 8, 22, 15, 250_000)

    first = OpentelemetryTrace.create!(
      timestamp: timestamp,
      span_name: "http",
      trace_id: "t1",
      span_id: "s1",
      span_attributes: { "http.request.method" => "GET" }
    )
    second = OpentelemetryTrace.create!(
      timestamp: timestamp,
      span_name: "http",
      trace_id: "t2",
      span_id: "s2",
      span_attributes: { "http.request.method" => "GET" }
    )

    described_class.new.perform(first.trace_id, first.span_id)
    described_class.new.perform(second.trace_id, second.span_id)

    rows = metric_rows("http_counter", [ "http_request_method" ])
    expect(rows.size).to eq(1)
    expect(rows.first["value"].to_i).to eq(2)
    expect(rows.first["http_request_method"]).to eq("GET")
  end

  it "raises WatermarkNotReady when a query metric has no watermark yet", :no_transaction do
    TraceToMetric.create!(
      name: "opentelemetry_traces_query_counter",
      span_name: TraceToMetric::QUERY_SPAN_NAME,
      metric_type: "counter",
      dimensions: [],
      filters: [],
      bucket_interval: "1 minute"
    )
    trace = create_trace!(name: "http", trace_id: "wm1", span_id: "wm1")

    expect {
      described_class.new.perform(trace.trace_id, trace.span_id)
    }.to raise_error(OpentelemetryTraceCreatedJob::WatermarkNotReady)
  end

  it "appends to a query metric only for spans after the watermark", :no_transaction do
    metric_name = "opentelemetry_traces_1_minute_span_kind_server_live_counter"
    TraceToMetric.create!(
      name: metric_name,
      span_name: TraceToMetric::QUERY_SPAN_NAME,
      metric_type: "counter",
      dimensions: [],
      filters: [ { "column" => "span_kind", "op" => "=", "value" => "SERVER" } ],
      bucket_interval: "1 minute",
      backfill_through_timestamp: Time.utc(2026, 1, 1, 10, 0, 0),
      backfill_through_trace_id: "mid",
      backfill_through_span_id: "mid"
    )

    before = OpentelemetryTrace.create!(
      timestamp: Time.utc(2026, 1, 1, 9, 59, 0),
      span_name: "http",
      trace_id: "before",
      span_id: "before",
      span_kind: "SERVER"
    )
    after = OpentelemetryTrace.create!(
      timestamp: Time.utc(2026, 1, 1, 10, 0, 1),
      span_name: "http",
      trace_id: "after",
      span_id: "after",
      span_kind: "SERVER"
    )

    described_class.new.perform(before.trace_id, before.span_id)
    described_class.new.perform(after.trace_id, after.span_id)

    rows = metric_rows(metric_name)
    expect(rows.size).to eq(1)
    expect(rows.first["value"].to_i).to eq(1)
  ensure
    drop_metric_tables(metric_name)
  end
end

