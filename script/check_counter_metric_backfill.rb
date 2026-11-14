#!/usr/bin/env ruby
# frozen_string_literal: true

# Run dashboard counter queries against POST /api/v1/sql, wait for backfill jobs,
# then re-run and compare results.
#
#   bin/rails runner script/check_counter_metric_backfill.rb
#
# Env:
#   SQL_API_URL   (default http://127.0.0.1:3000/api/v1/sql)
#   FROM_TS       (default 2026-10-22 14:00:00)
#   TO_TS         (default 2026-10-22 15:00:00)
#   POLL_SECONDS  (default 120)

require "json"
require "net/http"
require "uri"

API_URL = ENV.fetch("SQL_API_URL", "http://127.0.0.1:3000/api/v1/sql")
FROM_TS = ENV.fetch("FROM_TS", "2026-10-22 14:00:00")
TO_TS = ENV.fetch("TO_TS", "2026-10-22 15:00:00")
POLL_SECONDS = ENV.fetch("POLL_SECONDS", "120").to_i
PER = "1 minute"
SERVICE = "__all__"

SHARED = <<~SQL.squish
  timestamp >= '#{FROM_TS}'
  AND timestamp < '#{TO_TS}'
  AND ('#{SERVICE}' = '__all__' OR service_name = '#{SERVICE}')
SQL

QUERIES = {
  "Requests served" => <<~SQL.squish,
    SELECT COUNT(*) AS value FROM opentelemetry_traces
    WHERE #{SHARED}
      AND span_kind = 'SPAN_KIND_SERVER'
      AND "span_attributes.http.response.status_code" IS NOT NULL
  SQL
  "Jobs Executed" => <<~SQL.squish,
    SELECT COUNT(*) AS value FROM opentelemetry_traces
    WHERE #{SHARED}
      AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
  SQL
  "Mails Sent" => <<~SQL.squish,
    SELECT COUNT(*) AS value FROM opentelemetry_traces
    WHERE #{SHARED}
      AND scope_name = 'OpenTelemetry::Instrumentation::ActionMailer'
  SQL
  "Requests per minute ok" => <<~SQL.squish,
    SELECT date_bin('#{PER}', timestamp) AS time, COUNT(*) AS ok
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND span_kind = 'SPAN_KIND_SERVER'
      AND "span_attributes.http.response.status_code" IS NOT NULL
      AND "span_attributes.http.response.status_code" < 400
    GROUP BY time ORDER BY time
  SQL
  "Requests per minute error" => <<~SQL.squish,
    SELECT date_bin('#{PER}', timestamp) AS time, COUNT(*) AS error
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND span_kind = 'SPAN_KIND_SERVER'
      AND "span_attributes.http.response.status_code" IS NOT NULL
      AND "span_attributes.http.response.status_code" >= 400
    GROUP BY time ORDER BY time
  SQL
  "Jobs per minute succeeded" => <<~SQL.squish,
    SELECT date_bin('#{PER}', timestamp) AS time, COUNT(*) AS succeeded
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
      AND (span_status_code IS NULL OR span_status_code != 'STATUS_CODE_ERROR')
    GROUP BY time ORDER BY time
  SQL
  "Jobs per minute failed" => <<~SQL.squish,
    SELECT date_bin('#{PER}', timestamp) AS time, COUNT(*) AS failed
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
      AND span_status_code = 'STATUS_CODE_ERROR'
    GROUP BY time ORDER BY time
  SQL
  "Mails per minute" => <<~SQL.squish
    SELECT date_bin('#{PER}', timestamp) AS time, COUNT(*) AS mails
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND scope_name = 'OpenTelemetry::Instrumentation::ActionMailer'
    GROUP BY time ORDER BY time
  SQL
}.freeze

def post_sql(sql)
  uri = URI(API_URL)
  response = Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Post.new(uri)
    request["content-type"] = "application/json"
    request.body = JSON.generate({ "sql" => sql })
    http.request(request)
  end
  body = JSON.parse(response.body)
  raise "HTTP #{response.code}: #{body}" unless response.is_a?(Net::HTTPSuccess)

  body
end

def normalize_rows(rows)
  Array(rows).map do |row|
    row.transform_values do |value|
      case value
      when Float then value.round(6)
      else value
      end
    end
  end
end

def wait_for_backfill_jobs!(timeout_seconds)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  loop do
    pending = SolidQueue::Job
      .where(class_name: "TraceToMetrics::BackfillJob", finished_at: nil)
      .count
    failed = SolidQueue::FailedExecution
      .joins(:job)
      .where(solid_queue_jobs: { class_name: "TraceToMetrics::BackfillJob" })
      .count

    unfinished_metrics = TraceToMetric.query_metrics.reject(&:backfill_finished?).map(&:name)

    if failed.positive?
      abort "Backfill jobs failed (#{failed}). Check solid_queue_failed_executions."
    end

    if pending.zero? && unfinished_metrics.empty?
      puts "All TraceToMetrics::BackfillJob finished."
      return
    end

    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      abort "Timed out waiting for backfill. pending_jobs=#{pending} unfinished=#{unfinished_metrics.inspect}"
    end

    puts "Waiting for backfill… pending_jobs=#{pending} unfinished=#{unfinished_metrics.inspect}"
    sleep 2
  end
end

puts "POST #{API_URL}"
puts "Range #{FROM_TS} .. #{TO_TS}"

before = {}
QUERIES.each do |label, sql|
  body = post_sql(sql)
  before[label] = body
  puts format(
    "before %-28s used_metric=%-5s metric=%s rows=%d",
    label,
    body["used_metric"].inspect,
    body["metric_name"].inspect,
    Array(body["data"]).size
  )
end

wait_for_backfill_jobs!(POLL_SECONDS)

mismatches = []
QUERIES.each do |label, sql|
  body = post_sql(sql)
  left = normalize_rows(before[label]["data"])
  right = normalize_rows(body["data"])
  ok = left == right
  puts format(
    "after  %-28s used_metric=%-5s metric=%s rows=%d match=%s",
    label,
    body["used_metric"].inspect,
    body["metric_name"].inspect,
    Array(body["data"]).size,
    ok
  )
  mismatches << label unless ok
end

if mismatches.empty?
  puts "OK: all counter query results match after backfill."
else
  abort "Mismatch: #{mismatches.join(', ')}"
end
