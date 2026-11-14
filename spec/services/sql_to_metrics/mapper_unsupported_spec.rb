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

  it "allows timestamp bounds on a bare COUNT without date_bin" do
    sql = <<~SQL
      SELECT COUNT(*) AS value
      FROM opentelemetry_traces
      WHERE timestamp >= '2026-10-22 14:00:00'
        AND timestamp < '2026-10-22 15:00:00'
        AND ('__all__' = '__all__' OR service_name = '__all__')
        AND span_kind = 'SPAN_KIND_SERVER'
        AND "span_attributes.http.response.status_code" IS NOT NULL
    SQL

    result = described_class.call(sql)
    expect(result[:unsupported_predicates]).to eq(false)
    expect(result[:time_bucket]).to be_nil
    expect(result[:filters]).to contain_exactly(
      { column: "span_kind", op: "=", value: "SPAN_KIND_SERVER" },
      { column: "span_attributes.http.response.status_code", op: "IS NOT NULL" }
    )
  end
end
