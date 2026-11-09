require "rails_helper"

RSpec.describe "OTLP traces ingest", type: :request do
  describe "POST /v1/traces" do
    it "creates spans from an OTLP JSON payload" do
      payload = otlp_trace_payload(
        span_name: "http",
        attributes: { "http.request.method" => "GET", "http.route" => "/stories" }
      )

      expect {
        post "/v1/traces", params: payload, as: :json
      }.to change(Span, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("accepted" => 1)

      span = Span.last
      expect(span.span_name).to eq("http")
      expect(span.service_name).to eq("lobsters")
      expect(span.span_kind).to eq("SERVER")
      expect(span.span_status_code).to eq("OK")
      expect(span.duration_nano).to eq(1_000_000_000)
      expect(span.span_attributes).to include(
        "http.request.method" => "GET",
        "http.route" => "/stories"
      )
      expect(span.resource_attributes).to include("service.name" => "lobsters")
    end

    it "enqueues SpanCreatedJob for each created span", :no_transaction do
      payload = otlp_trace_payload(span_name: "http")

      expect {
        post "/v1/traces", params: payload, as: :json
      }.to have_enqueued_job(SpanCreatedJob)
    end

    it "accepts an empty resourceSpans list" do
      post "/v1/traces", params: { "resourceSpans" => [] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("accepted" => 0)
    end
  end
end
