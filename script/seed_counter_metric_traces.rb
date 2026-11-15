#!/usr/bin/env ruby
# frozen_string_literal: true

# Seed ActiveJob / ActionMailer spans so script/check_counter_metric_backfill.rb
# queries return non-empty results in FROM_TS..TO_TS.
#
#   bin/rails runner script/seed_counter_metric_traces.rb
#
# Env:
#   FROM_TS (default 2026-10-22 14:00:00) — used as the seed window start
#   SERVICE (default lobsters)

require "securerandom"

# Greptime / check script treat bare timestamps as UTC — force UTC, ignore local TZ.
FROM_TS = Time.parse("#{ENV.fetch("FROM_TS", "2026-10-22 14:00:00")} UTC")
SERVICE = ENV.fetch("SERVICE", "lobsters")

# Spread across minutes that already have request traffic in the check window.
MINUTES = [
  FROM_TS + 20 * 60, # 14:20
  FROM_TS + 21 * 60, # 14:21
  FROM_TS + 22 * 60  # 14:22
].freeze

def insert!(attrs)
  OpentelemetryTrace.create!(
    {
      trace_id: SecureRandom.hex(16),
      span_id: SecureRandom.hex(8),
      service_name: SERVICE,
      span_attributes: {},
      resource_attributes: {}
    }.merge(attrs)
  )
end

created = 0

MINUTES.each_with_index do |minute, i|
  # Jobs succeeded (null status and OK both match the dashboard filter)
  3.times do |n|
    insert!(
      timestamp: minute + n,
      span_name: "perform_job",
      span_kind: "SPAN_KIND_INTERNAL",
      span_status_code: n.even? ? nil : "STATUS_CODE_OK",
      scope_name: "OpenTelemetry::Instrumentation::ActiveJob"
    )
    created += 1
  end

  # Jobs failed
  2.times do |n|
    insert!(
      timestamp: minute + 10 + n,
      span_name: "perform_job",
      span_kind: "SPAN_KIND_INTERNAL",
      span_status_code: "STATUS_CODE_ERROR",
      span_status_message: "boom",
      scope_name: "OpenTelemetry::Instrumentation::ActiveJob"
    )
    created += 1
  end

  # Mails sent
  2.times do |n|
    insert!(
      timestamp: minute + 20 + n,
      span_name: "deliver",
      span_kind: "SPAN_KIND_INTERNAL",
      span_status_code: "STATUS_CODE_OK",
      scope_name: "OpenTelemetry::Instrumentation::ActionMailer"
    )
    created += 1
  end

  # A few extra server spans with status codes so ok/error counters stay populated
  # even if the imported dump is later truncated.
  insert!(
    timestamp: minute + 30 + i,
    span_name: "HTTP GET",
    span_kind: "SPAN_KIND_SERVER",
    span_status_code: "STATUS_CODE_OK",
    scope_name: "OpenTelemetry::Instrumentation::Rack",
    span_attributes: { "http.response.status_code" => 200, "http.request.method" => "GET" }
  )
  created += 1

  insert!(
    timestamp: minute + 40 + i,
    span_name: "HTTP GET",
    span_kind: "SPAN_KIND_SERVER",
    span_status_code: "STATUS_CODE_ERROR",
    scope_name: "OpenTelemetry::Instrumentation::Rack",
    span_attributes: { "http.response.status_code" => 500, "http.request.method" => "GET" }
  )
  created += 1
end

puts "Inserted #{created} spans for service=#{SERVICE} minutes=#{MINUTES.map(&:iso8601).inspect}"
