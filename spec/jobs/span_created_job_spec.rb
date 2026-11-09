require "rails_helper"

RSpec.describe SpanCreatedJob, type: :job do
  def create_span!(name: "http")
    Span.create!(
      timestamp: Time.current,
      span_name: name,
      trace_id: "abc",
      span_id: "def"
    )
  end

  it "returns when the span is missing" do
    expect(SpanToMetrics::Injector).not_to receive(:call)
    described_class.new.perform(-1)
  end

  it "skips injection when no SpanToMetric matches the span_name" do
    span = create_span!(name: "http")

    expect(SpanToMetrics::Injector).not_to receive(:call)
    described_class.new.perform(span.id)
  end

  it "calls Injector when a SpanToMetric matches", :no_transaction do
    definition = SpanToMetric.create!(
      span_name: "http",
      metric_type: "counter",
      dimensions: [ "http.method" ]
    )
    span = create_span!(name: "http")

    expect(SpanToMetrics::Injector).to receive(:call).with(span, definition)
    described_class.new.perform(span.id)
  end
end
