module Otlp
  class TracesController < ActionController::API
    def create
      payload = parse_payload
      result = Traces::Ingest.call(payload)

      render json: { accepted: result.count }, status: :ok
    end

    private

    def parse_payload
      body = request.request_parameters
      body = body.to_unsafe_h if body.respond_to?(:to_unsafe_h)
      body.is_a?(Hash) ? body : {}
    end
  end
end
