# frozen_string_literal: true

require "rails_helper"

RSpec.describe GaugeMetrics::EnsureMetric, :no_transaction do
  let(:sql) {
    <<~SQL
      SELECT AVG(duration_nano) / 1e6 AS value
      FROM opentelemetry_traces
      WHERE span_kind = 'SPAN_KIND_SERVER'
        AND "span_attributes.http.response.status_code" IS NOT NULL
    SQL
  }
  let(:metric_name) {
    "opentelemetry_traces_span_kind_span_kind_server_" \
      "span_attributes_http_response_status_code_is_not_null_avg_duration_nano_gauge"
  }

  after { drop_metric_tables(metric_name) }

  it "creates a gauge metric definition and enqueues backfill" do
    expect {
      result = described_class.new(sql).call
      expect(result.created).to eq(true)
      expect(result.enqueued_backfill).to eq(true)
      expect(result.metric_name).to eq(metric_name)
    }.to have_enqueued_job(TraceToMetrics::BackfillJob).with(metric_name)

    definition = TraceToMetric.find(metric_name)
    expect(definition.metric_type).to eq("gauge")
    expect(definition.bucket_interval).to eq("1 minute")
    expect(Greptime::Connection.table_exists?(metric_name)).to eq(true)
    expect(Greptime::Connection.column_names(metric_name)).to include("value_sum", "value_count")
  end

  it "is a no-op when the metric already exists" do
    described_class.new(sql).call

    expect {
      result = described_class.new(sql).call
      expect(result.created).to eq(false)
      expect(result.enqueued_backfill).to eq(false)
    }.not_to have_enqueued_job(TraceToMetrics::BackfillJob)
  end
end
