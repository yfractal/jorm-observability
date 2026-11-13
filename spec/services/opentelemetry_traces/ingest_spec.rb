require "rails_helper"

RSpec.describe OpentelemetryTraces::Ingest do
  it "parses nested OTLP resource/scope/spans into OpentelemetryTrace rows" do
    payload = otlp_trace_payload(
      span_name: "select",
      attributes: { "db.system" => "postgresql" }
    )

    result = nil
    expect {
      result = described_class.call(payload)
    }.to change(OpentelemetryTrace, :count).by(1)

    expect(result.count).to eq(1)
    trace = result.traces.first
    expect(trace.span_name).to eq("select")
    expect(trace.span_attributes["db.system"]).to eq("postgresql")
    expect(trace.scope_name).to eq("test-scope")
  end
end
