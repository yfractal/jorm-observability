require "rails_helper"

RSpec.describe "OTLP traces ingest", type: :request do
  describe "POST /v1/traces" do
    it "creates traces from an OTLP JSON payload" do
      payload = otlp_trace_payload(
        span_name: "http",
        attributes: { "http.request.method" => "GET", "http.route" => "/stories" }
      )

      expect {
        post "/v1/traces", params: payload, as: :json
      }.to change(OpentelemetryTrace, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("accepted" => 1)

      trace = OpentelemetryTrace.find_by!(
        trace_id: "5b8aa5a2d2c872e8321cf37308d69df2",
        span_id: "051581bf3cb55c13"
      )
      expect(trace.span_name).to eq("http")
      expect(trace.service_name).to eq("lobsters")
      expect(trace.span_kind).to eq("SERVER")
      expect(trace.span_status_code).to eq("OK")
      expect(trace.duration_nano).to eq(1_000_000_000)
      expect(trace.span_attributes).to include(
        "http.request.method" => "GET",
        "http.route" => "/stories"
      )
      expect(trace.resource_attributes).to include("service.name" => "lobsters")
    end

    it "enqueues OpentelemetryTraceCreatedJob for each created trace", :no_transaction do
      payload = otlp_trace_payload(span_name: "http")

      expect {
        post "/v1/traces", params: payload, as: :json
      }.to have_enqueued_job(OpentelemetryTraceCreatedJob)
    end

    it "accepts an empty resourceSpans list" do
      post "/v1/traces", params: { "resourceSpans" => [] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("accepted" => 0)
    end
  end
end
