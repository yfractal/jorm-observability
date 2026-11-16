require "rails_helper"

RSpec.describe SqlToMetrics::EnsureMetric, :no_transaction do
  after do
    drop_metric_tables(
      "opentelemetry_traces_1_minute_parent_span_id_is_null_counter",
      "opentelemetry_traces_parent_span_id_is_null_counter",
      "opentelemetry_traces_1_minute_span_kind_span_kind_server_" \
      "span_attributes_http_response_status_code_is_not_null_" \
      "span_attributes_http_response_status_code_lt_400_counter"
    )
  end

  it "creates a query metric, stores a watermark, and enqueues backfill" do
    OpentelemetryTrace.create!(
      timestamp: Time.utc(2026, 1, 1, 10, 0, 0),
      span_name: "http",
      trace_id: "t-ensure-1",
      span_id: "s-ensure-1",
      parent_span_id: nil
    )

    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS c
      FROM opentelemetry_traces
      WHERE parent_span_id IS NULL
        AND timestamp >= '2026-01-01 10:00:00'
        AND timestamp < '2026-01-01 11:00:00'
      GROUP BY time
    SQL

    expect {
      @result = described_class.new(sql).call
    }.to have_enqueued_job(TraceToMetrics::BackfillJob)

    expect(@result.created).to eq(true)
    expect(@result.enqueued_backfill).to eq(true)
    expect(@result.metric_name).to eq(
      "opentelemetry_traces_1_minute_parent_span_id_is_null_counter"
    )

    definition = TraceToMetric.find(@result.metric_name)
    expect(definition.query_metric?).to eq(true)
    expect(definition.filters).to contain_exactly(
      a_hash_including("column" => "parent_span_id", "op" => "IS NULL")
    )
    expect(definition.bucket_interval).to eq("1 minute")
    expect(definition.watermark_ready?).to eq(true)
    trace = OpentelemetryTrace.find_by(trace_id: "t-ensure-1", span_id: "s-ensure-1")
    expect(definition.after_watermark?(trace)).to eq(false)
    expect(Greptime::Connection.table_exists?(definition.name)).to eq(true)
  end

  it "does not enqueue again when the metric already exists" do
    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS c
      FROM opentelemetry_traces
      WHERE parent_span_id IS NULL
      GROUP BY time
    SQL

    described_class.new(sql).call
    expect {
      result = described_class.new(sql).call
      expect(result.created).to eq(false)
      expect(result.enqueued_backfill).to eq(false)
    }.not_to have_enqueued_job(TraceToMetrics::BackfillJob)
  end

  it "skips metrics when the query has unsupported predicates" do
    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS c
      FROM opentelemetry_traces
      WHERE span_status_code IN ('STATUS_CODE_ERROR', 'STATUS_CODE_OK')
      GROUP BY time
    SQL

    result = described_class.new(sql).call
    expect(result.created).to eq(false)
    expect(result.metric_name).to be_nil
  end

  it "creates a metric for (IS NULL OR !=) succeeded filters" do
    metric_name =
      "opentelemetry_traces_1_minute_scope_name_opentelemetry_instrumentation_activejob_" \
      "span_status_code_is_null_or_ne_status_code_error_counter"
    drop_metric_tables(metric_name)

    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS succeeded
      FROM opentelemetry_traces
      WHERE scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
        AND (span_status_code IS NULL OR span_status_code != 'STATUS_CODE_ERROR')
      GROUP BY time
    SQL

    expect {
      @result = described_class.new(sql).call
    }.to have_enqueued_job(TraceToMetrics::BackfillJob)

    expect(@result.created).to eq(true)
    expect(@result.metric_name).to eq(metric_name)
    definition = TraceToMetric.find(metric_name)
    expect(definition.filters).to include(
      a_hash_including(
        "column" => "span_status_code",
        "op" => SqlToMetrics::Mapper::NULL_OR_NOT_EQUAL_OP,
        "value" => "STATUS_CODE_ERROR"
      )
    )
  ensure
    drop_metric_tables(metric_name)
  end

  it "creates a metric for status_code comparison filters" do
    ok_name =
      "opentelemetry_traces_1_minute_span_kind_span_kind_server_" \
      "span_attributes_http_response_status_code_is_not_null_" \
      "span_attributes_http_response_status_code_lt_400_counter"
    drop_metric_tables(ok_name)

    sql = <<~SQL
      SELECT date_bin('1 minute', timestamp) AS time, COUNT(*) AS ok
      FROM opentelemetry_traces
      WHERE span_kind = 'SPAN_KIND_SERVER'
        AND "span_attributes.http.response.status_code" IS NOT NULL
        AND "span_attributes.http.response.status_code" < 400
      GROUP BY time
    SQL

    expect {
      @result = described_class.new(sql).call
    }.to have_enqueued_job(TraceToMetrics::BackfillJob)

    expect(@result.created).to eq(true)
    expect(@result.metric_name).to eq(
      "opentelemetry_traces_1_minute_span_kind_span_kind_server_" \
      "span_attributes_http_response_status_code_is_not_null_" \
      "span_attributes_http_response_status_code_lt_400_counter"
    )
  end
end
