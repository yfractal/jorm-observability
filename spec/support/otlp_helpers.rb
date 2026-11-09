module OtlpHelpers
  def otlp_trace_payload(span_name: "http", service_name: "lobsters", attributes: {})
    {
      "resourceSpans" => [
        {
          "resource" => {
            "attributes" => [
              { "key" => "service.name", "value" => { "stringValue" => service_name } }
            ]
          },
          "scopeSpans" => [
            {
              "scope" => { "name" => "test-scope", "version" => "1.0.0" },
              "spans" => [
                {
                  "traceId" => "5b8aa5a2d2c872e8321cf37308d69df2",
                  "spanId" => "051581bf3cb55c13",
                  "name" => span_name,
                  "kind" => 2,
                  "startTimeUnixNano" => "1544712660000000000",
                  "endTimeUnixNano" => "1544712661000000000",
                  "attributes" => attributes.map do |key, value|
                    { "key" => key.to_s, "value" => { "stringValue" => value.to_s } }
                  end,
                  "status" => { "code" => 1 }
                }
              ]
            }
          ]
        }
      ]
    }
  end
end

RSpec.configure do |config|
  config.include OtlpHelpers
end
