# frozen_string_literal: true

require "rails_helper"

RSpec.describe TraceToMetrics::BackfillJob, "gauge", :no_transaction do
  let(:metric_name) {
    "opentelemetry_traces_1_minute_span_kind_span_kind_server_avg_duration_nano_gauge"
  }

  after { drop_metric_tables(metric_name) }

  def create_query_metric!
    TraceToMetric.create!(
      name: metric_name,
      span_name: TraceToMetric::QUERY_SPAN_NAME,
      metric_type: "gauge",
      dimensions: [],
      filters: [ { "column" => "span_kind", "op" => "=", "value" => "SPAN_KIND_SERVER" } ],
      bucket_interval: "1 minute",
      backfill_through_timestamp: Time.utc(2026, 1, 1, 10, 5, 0),
      backfill_through_trace_id: "zzz",
      backfill_through_span_id: "zzz"
    )
  end

  it "aggregates SUM/COUNT of duration_nano for matching spans" do
    create_query_metric!
    OpentelemetryTrace.create!(
      timestamp: Time.utc(2026, 1, 1, 10, 1, 30),
      span_name: "http",
      trace_id: "t1",
      span_id: "s1",
      span_kind: "SPAN_KIND_SERVER",
      duration_nano: 2_000_000
    )
    OpentelemetryTrace.create!(
      timestamp: Time.utc(2026, 1, 1, 10, 1, 45),
      span_name: "http",
      trace_id: "t2",
      span_id: "s2",
      span_kind: "SPAN_KIND_SERVER",
      duration_nano: 4_000_000
    )
    OpentelemetryTrace.create!(
      timestamp: Time.utc(2026, 1, 1, 10, 1, 0),
      span_name: "db",
      trace_id: "t3",
      span_id: "s3",
      span_kind: "CLIENT",
      duration_nano: 9_000_000
    )

    described_class.new.perform(metric_name)

    definition = TraceToMetric.find(metric_name)
    expect(definition.backfill_finished?).to eq(true)

    rows = TraceToMetrics::Gauge::Injector.summed_rows(metric_name)
    expect(rows.size).to eq(1)
    expect(rows.first["value_sum"].to_f).to eq(6_000_000.0)
    expect(rows.first["value_count"].to_i).to eq(2)
  end
end
