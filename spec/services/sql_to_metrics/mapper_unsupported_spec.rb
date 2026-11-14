require "rails_helper"

RSpec.describe SqlToMetrics::Mapper do
  it "flags comparison filters as unsupported predicates" do
    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS c
      FROM opentelemetry_traces
      WHERE "span_attributes.http.response.status_code" < 400
      GROUP BY time
    SQL

    result = described_class.call(sql)
    expect(result[:unsupported_predicates]).to eq(true)
    expect(result[:filters]).to eq([])
  end

  it "skips Grafana All-service tautology OR and keeps other filters" do
    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS c
      FROM opentelemetry_traces
      WHERE ('__all__' = '__all__' OR service_name = '__all__')
        AND span_kind = 'SPAN_KIND_SERVER'
      GROUP BY time
    SQL

    result = described_class.call(sql)
    expect(result[:unsupported_predicates]).to eq(false)
    expect(result[:filters]).to contain_exactly(
      { column: "span_kind", op: "=", value: "SPAN_KIND_SERVER" }
    )
  end
end
