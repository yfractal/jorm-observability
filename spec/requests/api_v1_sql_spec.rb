require "rails_helper"

RSpec.describe "API v1 SQL", type: :request do
  describe "POST /api/v1/sql" do
    it "runs a SELECT and returns row data" do
      OpentelemetryTrace.create!(
        timestamp: Time.utc(2026, 1, 1, 12, 0, 0),
        span_name: "http",
        trace_id: SecureRandom.hex(16),
        span_id: SecureRandom.hex(8),
        service_name: "lobsters",
        span_kind: "SERVER",
        span_status_code: "OK",
        scope_name: "app",
        span_attributes: {},
        resource_attributes: {}
      )

      post "/api/v1/sql",
           params: { sql: "SELECT service_name, COUNT(*) AS count FROM opentelemetry_traces GROUP BY service_name" },
           as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["data"]).to contain_exactly(
        a_hash_including("service_name" => "lobsters", "count" => 1)
      )
      expect(body).to include("sql", "used_metric", "metric_name")
    end

    it "returns an empty data array when there are no rows" do
      post "/api/v1/sql",
           params: { sql: "SELECT * FROM opentelemetry_traces WHERE 1 = 0" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq([])
    end

    it "rejects non-SELECT statements" do
      post "/api/v1/sql",
           params: { sql: "DELETE FROM opentelemetry_traces" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to match(/only SELECT/i)
    end

    it "returns bad request for invalid Greptime SQL" do
      post "/api/v1/sql",
           params: { sql: "SELECT * FROM definitely_missing_table_xyz" },
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to be_present
    end
  end
end
