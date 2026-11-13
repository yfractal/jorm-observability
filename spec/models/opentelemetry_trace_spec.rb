require "rails_helper"

RSpec.describe OpentelemetryTrace, type: :model do
  it "enqueues OpentelemetryTraceCreatedJob after create", :no_transaction do
    expect {
      described_class.create!(
        timestamp: Time.current,
        span_name: "http",
        trace_id: "t1",
        span_id: "s1"
      )
    }.to have_enqueued_job(OpentelemetryTraceCreatedJob).with("t1", "s1")
  end

  it "stores and reads flattened span and resource attributes", :no_transaction do
    described_class.create!(
      timestamp: Time.current,
      span_name: "http",
      trace_id: "t-attr",
      span_id: "s-attr",
      service_name: "lobsters",
      span_attributes: { "http.request.method" => "GET", "http.route" => "/stories" },
      resource_attributes: { "deployment.environment" => "production", "service.name" => "lobsters" }
    )

    trace = described_class.find_by!(trace_id: "t-attr", span_id: "s-attr")
    expect(trace.span_attributes).to include(
      "http.request.method" => "GET",
      "http.route" => "/stories"
    )
    expect(trace.resource_attributes).to include(
      "deployment.environment" => "production",
      "service.name" => "lobsters"
    )
  end
end
