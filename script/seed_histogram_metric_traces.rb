#!/usr/bin/env ruby
# frozen_string_literal: true

# Seed ActiveJob spans WITH duration_nano so the ActiveJob p99/p95/p50 queries in
# script/check_histogram_metric_backfill.rb return non-empty results. Imported dumps
# have job/mail spans without durations, so approx_percentile_cont is NULL there.
#
#   bin/rails runner script/seed_histogram_metric_traces.rb
#
# Env:
#   FROM_TS (default 2026-10-22 14:00:00) — seed window start (UTC)
#   SERVICE (default lobsters)
#   MINUTES (default 25..45) — comma-free "from..to" minute offsets from FROM_TS

require "securerandom"

FROM_TS = Time.parse("#{ENV.fetch("FROM_TS", "2026-10-22 14:00:00")} UTC")
SERVICE = ENV.fetch("SERVICE", "lobsters")
MINUTE_RANGE = Range.new(*ENV.fetch("MINUTES", "25..45").split("..").map(&:to_i))

# Log-spread job durations (1 ms .. ~2 s) so quantiles differ.
def job_duration_nano(seed)
  (1_000_000 * (1.35**(seed % 25))).to_i
end

created = 0
MINUTE_RANGE.each do |minute|
  6.times do |n|
    OpentelemetryTrace.create!(
      trace_id: SecureRandom.hex(16),
      span_id: SecureRandom.hex(8),
      service_name: SERVICE,
      timestamp: FROM_TS + minute * 60 + n * 7,
      timestamp_end: FROM_TS + minute * 60 + n * 7 + 1,
      duration_nano: job_duration_nano(minute * 6 + n),
      span_name: "perform_job",
      span_kind: "SPAN_KIND_INTERNAL",
      span_status_code: n == 5 ? "STATUS_CODE_ERROR" : "STATUS_CODE_OK",
      scope_name: "OpenTelemetry::Instrumentation::ActiveJob",
      span_attributes: {},
      resource_attributes: {}
    )
    created += 1
  end
end

puts "Inserted #{created} ActiveJob spans with duration_nano for service=#{SERVICE}"
