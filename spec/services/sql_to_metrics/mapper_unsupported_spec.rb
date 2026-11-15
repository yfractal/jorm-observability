require "rails_helper"

RSpec.describe SqlToMetrics::Mapper do
  it "accepts comparison filters as supported predicates" do
    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS c
      FROM opentelemetry_traces
      WHERE "span_attributes.http.response.status_code" < 400
      GROUP BY time
    SQL

    result = described_class.call(sql)
    expect(result[:unsupported_predicates]).to eq(false)
    expect(result[:filters]).to contain_exactly(
      { column: "span_attributes.http.response.status_code", op: "<", value: 400 }
    )
  end

  it "accepts (col IS NULL OR col != value) as a supported filter" do
    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS succeeded
      FROM opentelemetry_traces
      WHERE scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
        AND (span_status_code IS NULL OR span_status_code != 'STATUS_CODE_ERROR')
      GROUP BY time
    SQL

    result = described_class.call(sql)
    expect(result[:unsupported_predicates]).to eq(false)
    expect(result[:filters]).to contain_exactly(
      { column: "scope_name", op: "=", value: "OpenTelemetry::Instrumentation::ActiveJob" },
      {
        column: "span_status_code",
        op: SqlToMetrics::Mapper::NULL_OR_NOT_EQUAL_OP,
        value: "STATUS_CODE_ERROR"
      }
    )
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
