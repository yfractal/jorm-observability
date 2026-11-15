#!/usr/bin/env ruby
# frozen_string_literal: true

# Seed spans with duration_nano so script/check_gauge_metric_backfill.rb
# gauge queries return non-empty results in FROM_TS..TO_TS.
#
#   bin/rails runner script/seed_gauge_metric_traces.rb
#
# Env:
#   FROM_TS (default 2026-10-22 14:00:00) — used as the seed window start
#   SERVICE (default lobsters)

require "securerandom"

FROM_TS = Time.parse("#{ENV.fetch("FROM_TS", "2026-10-22 14:00:00")} UTC")
SERVICE = ENV.fetch("SERVICE", "lobsters")

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
  # Server / controller spans (Average Response + Controller Action Performance)
  3.times do |n|
    insert!(
      timestamp: minute + n,
      span_name: "HTTP GET",
      span_kind: "SPAN_KIND_SERVER",
      span_status_code: "STATUS_CODE_OK",
      duration_nano: (10_000_000 + (i * 1_000_000) + (n * 500_000)),
      span_attributes: { "http.response.status_code" => 200 }
    )
    created += 1
  end

  # Database spans (Average Database Response + Database Query Performance)
  3.times do |n|
    insert!(
      timestamp: minute + 10 + n,
      span_name: "SELECT",
      span_kind: "SPAN_KIND_CLIENT",
      span_status_code: "STATUS_CODE_OK",
      duration_nano: (2_000_000 + (n * 250_000)),
      span_attributes: { "db.system" => "postgresql" }
    )
    created += 1
  end

  # ActiveJob spans (Average Job Execution + ActiveJob Performance)
  2.times do |n|
    insert!(
      timestamp: minute + 20 + n,
      span_name: "perform_job",
      span_kind: "SPAN_KIND_INTERNAL",
      span_status_code: "STATUS_CODE_OK",
      duration_nano: (50_000_000 + (n * 5_000_000)),
      scope_name: "OpenTelemetry::Instrumentation::ActiveJob"
    )
    created += 1
  end
end

puts "Seeded #{created} gauge spans for service=#{SERVICE} from #{FROM_TS.utc.iso8601}"
