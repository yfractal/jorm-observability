require "rails_helper"

RSpec.describe Spans::Ingest do
  it "parses nested OTLP resource/scope/spans into Span rows" do
    payload = otlp_trace_payload(
      span_name: "select",
      attributes: { "db.system" => "postgresql" }
    )

    result = nil
    expect {
      result = described_class.call(payload)
    }.to change(Span, :count).by(1)

    expect(result.count).to eq(1)
    span = result.spans.first
    expect(span.span_name).to eq("select")
    expect(span.span_attributes["db.system"]).to eq("postgresql")
    expect(span.scope_name).to eq("test-scope")
  end
end
