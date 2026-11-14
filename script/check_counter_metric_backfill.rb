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

def span_count
  body = post_sql("SELECT COUNT(*) AS c FROM opentelemetry_traces")
  Array(body["data"]).dig(0, "c").to_i
end

def failed_backfill_executions
  SolidQueue::FailedExecution
    .joins(:job)
    .where(solid_queue_jobs: { class_name: "TraceToMetrics::BackfillJob" })
end

def latest_trace_watermark
  row = Greptime::Connection.exec_query(<<~SQL.squish).to_a.first
    SELECT timestamp, trace_id, span_id
    FROM opentelemetry_traces
    ORDER BY timestamp DESC, trace_id DESC, span_id DESC
    LIMIT 1
  SQL
  return nil if row.nil?

  {
    backfill_through_timestamp: Time.parse(row["timestamp"].to_s).utc,
    backfill_through_trace_id: row["trace_id"].to_s,
    backfill_through_span_id: row["span_id"].to_s,
    backfill_finished_at: nil
  }
end

def refresh_stale_watermarks!
  epoch = Time.utc(1970, 1, 1)
  watermark = latest_trace_watermark
  return unless watermark

  TraceToMetric.query_metrics.reject(&:backfill_finished?).each do |definition|
    next unless definition.backfill_through_timestamp.nil? ||
      definition.backfill_through_timestamp.utc <= epoch

    puts "Refresh watermark for #{definition.name}"
    definition.update_columns(watermark)
  end
end

def recover_failed_backfills!
  failed = failed_backfill_executions.includes(:job).to_a
  return if failed.empty?

  puts "Recovering #{failed.size} failed TraceToMetrics::BackfillJob execution(s)…"
  failed.each do |execution|
    job = execution.job
    metric_name = Array(job.arguments["arguments"] || job.arguments[:arguments]).first
    puts "  retry #{metric_name.inspect}: #{execution.error.to_s[0, 120]}"
    execution.destroy!
    job.destroy! if job.finished_at.nil?
    TraceToMetrics::BackfillJob.perform_later(metric_name) if metric_name.present?
  end
end

def wait_for_backfill_jobs!(timeout_seconds)
  refresh_stale_watermarks!
  recover_failed_backfills!

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  loop do
    pending = SolidQueue::Job
      .where(class_name: "TraceToMetrics::BackfillJob", finished_at: nil)
      .count
    failed = failed_backfill_executions.count
    unfinished_metrics = TraceToMetric.query_metrics.reject(&:backfill_finished?).map(&:name)

    if failed.positive?
      details = failed_backfill_executions.includes(:job).map { |f|
        args = f.job.arguments
        name = Array(args["arguments"] || args[:arguments]).first
        "#{name}: #{f.error.to_s[0, 160]}"
      }
      abort "Backfill jobs failed (#{failed}):\n  #{details.join("\n  ")}\nIs bin/jobs running?"
    end

    if pending.zero? && unfinished_metrics.empty?
      puts "All TraceToMetrics::BackfillJob finished."
      return
    end

    # Unfinished metrics with no pending/failed job — re-enqueue.
    if pending.zero? && unfinished_metrics.any?
      unfinished_metrics.each do |name|
        puts "Re-enqueue backfill for #{name}"
        TraceToMetrics::BackfillJob.perform_later(name)
      end
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

count = span_count
puts "opentelemetry_traces rows: #{count}"
if count.zero?
  abort "No spans loaded. Import traces first, then re-run this script with bin/jobs running."
end

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
