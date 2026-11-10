require "rails_helper"

RSpec.describe TraceCreatedJob, type: :job do
  def create_trace!(name: "http")
    Trace.create!(
      timestamp: Time.current,
      span_name: name,
      trace_id: "abc",
      span_id: "def"
    )
  end

  it "returns when the trace is missing" do
    expect(TraceToMetrics::Injector).not_to receive(:call)
    described_class.new.perform(-1)
  end

  it "skips injection when no TraceToMetric matches the span_name" do
    trace = create_trace!(name: "http")

    expect(TraceToMetrics::Injector).not_to receive(:call)
    described_class.new.perform(trace.id)
  end

  it "calls Injector when a TraceToMetric matches", :no_transaction do
    definition = TraceToMetric.create!(
      span_name: "http",
      metric_type: "counter",
      dimensions: [ "http.method" ]
    )
    trace = create_trace!(name: "http")

    expect(TraceToMetrics::Injector).to receive(:call).with(trace, definition)
    described_class.new.perform(trace.id)
  end

  it "increments the metric table end-to-end", :no_transaction do
    TraceToMetric.create!(
      span_name: "http",
      metric_type: "counter",
      dimensions: [ "http.request.method" ]
    )
    timestamp = Time.utc(2026, 11, 10, 8, 22, 15, 250_000)

    first = Trace.create!(
      timestamp: timestamp,
      span_name: "http",
      trace_id: "t1",
      span_id: "s1",
      span_attributes: { "http.request.method" => "GET" }
    )
    second = Trace.create!(
      timestamp: timestamp,
      span_name: "http",
      trace_id: "t2",
      span_id: "s2",
      span_attributes: { "http.request.method" => "GET" }
    )

    described_class.new.perform(first.id)
    described_class.new.perform(second.id)

    rows = ActiveRecord::Base.connection.exec_query("SELECT * FROM http_counter").to_a
    expect(rows.size).to eq(1)
    expect(rows.first["value"]).to eq(2)
    expect(rows.first["http_request_method"]).to eq("GET")
  end
end
