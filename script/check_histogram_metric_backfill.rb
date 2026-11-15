#!/usr/bin/env ruby
# frozen_string_literal: true

# Run dashboard histogram (p99 / p95 / p50) queries against POST /api/v1/sql, wait for
# backfill jobs, then re-run and compare results. Histogram counterpart of
# script/check_counter_metric_backfill.rb.
#
#   bin/rails runner script/check_histogram_metric_backfill.rb
#
# "before" runs the raw approx_percentile_cont query (the first call also creates the
# histogram metric and enqueues its backfill). "after" must be served from the
# metric table (used_metric=true) and agree within REL_TOL: the metric holds UDDSketch
# states, the raw query uses a different approximation, so results are close, not equal.
#
# Env:
#   SQL_API_URL   (default http://127.0.0.1:3000/api/v1/sql)
#   FROM_TS       (default 2026-10-22 14:00:00)
#   TO_TS         (default 2026-10-22 15:00:00)
#   POLL_SECONDS  (default 120)
#   REL_TOL       (default 0.05, max relative difference per value)
#   ABS_TOL       (default 50, a value also passes if it differs by at most this
#                  many output units (ms); sparse buckets, e.g. 2 spans, make the raw
#                  query interpolate between samples while a sketch returns one of them)
#   TIME_BUCKETS  (optional comma list; default all Grafana $per values)

require "json"
require "net/http"
require "uri"

API_URL = ENV.fetch("SQL_API_URL", "http://127.0.0.1:3000/api/v1/sql")
FROM_TS = ENV.fetch("FROM_TS", "2026-10-22 14:00:00")
TO_TS = ENV.fetch("TO_TS", "2026-10-22 15:00:00")
POLL_SECONDS = ENV.fetch("POLL_SECONDS", "120").to_i
REL_TOL = ENV.fetch("REL_TOL", "0.05").to_f
ABS_TOL = ENV.fetch("ABS_TOL", "50").to_f
SERVICE = "__all__"

TIME_BUCKETS = ENV.fetch(
  "TIME_BUCKETS",
  "1 minute,5 minutes,10 minutes,30 minutes,1 hour"
).split(",").map(&:strip).reject(&:empty?).freeze

SHARED = <<~SQL.squish
  timestamp >= '#{FROM_TS}'
  AND timestamp < '#{TO_TS}'
  AND ('#{SERVICE}' = '__all__' OR service_name = '#{SERVICE}')
SQL

# Each dashboard panel runs the same statement for these quantiles.
QUANTILES = { "p99" => 0.99, "p95" => 0.95, "p50" => 0.50 }.freeze

PANELS = {
  "Controller Action" => <<~SQL.squish,
    span_kind = 'SPAN_KIND_SERVER'
    AND "span_attributes.http.response.status_code" IS NOT NULL
  SQL
  "Database Query" => <<~SQL.squish,
    "span_attributes.db.system" IS NOT NULL
  SQL
  "ActiveJob" => <<~SQL.squish
    scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
  SQL
}.freeze

def bucket_queries(per)
  PANELS.each_with_object({}) do |(panel, predicate), queries|
    QUANTILES.each do |name, quantile|
      queries["#{panel} #{name} per #{per}"] = <<~SQL.squish
        SELECT date_bin('#{per}', timestamp) AS time,
               approx_percentile_cont(duration_nano, #{quantile}) / 1e6 AS #{name}
        FROM opentelemetry_traces
        WHERE #{SHARED}
          AND #{predicate}
        GROUP BY time ORDER BY time
      SQL
    end
  end
end

def post_sql(sql)
  uri = URI(API_URL)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Post.new(uri)
    request["content-type"] = "application/json"
    request.body = JSON.generate({ "sql" => sql })
    http.request(request)
  end
  latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  unless response["content-type"].to_s.include?("json")
    snippet = response.body.to_s[/<h2[^>]*>\s*(?:<[^>]+>\s*)*([^<]+)/m, 1] ||
      response.body.to_s[/exception-message[^>]*>.*?message[^>]*>\s*([^<]+)/m, 1] ||
      response.body.to_s[0, 300]
    raise "HTTP #{response.code} non-JSON from #{API_URL}: #{snippet.to_s.strip}"
  end

  body = JSON.parse(response.body)
  raise "HTTP #{response.code}: #{body}" unless response.is_a?(Net::HTTPSuccess)

  body.merge("_latency_ms" => latency_ms)
end

# Same time buckets, same row count, and every numeric value within REL_TOL.
def rows_match?(before_rows, after_rows)
  max_relative_error(before_rows, after_rows) <= REL_TOL
end

def max_relative_error(before_rows, after_rows)
  before_rows = Array(before_rows)
  after_rows = Array(after_rows)
  return Float::INFINITY unless before_rows.size == after_rows.size

  before_rows.zip(after_rows).map { |b, a|
    next Float::INFINITY unless b.keys == a.keys

    b.map { |key, bv|
      av = a[key]
      if bv.is_a?(Numeric) && av.is_a?(Numeric)
        denominator = [ bv.abs, av.abs ].max
        next 0.0 if denominator.zero? || (bv - av).abs <= ABS_TOL

        (bv - av).abs / denominator
      else
        bv == av ? 0.0 : Float::INFINITY
      end
    }.max || 0.0
  }.max || 0.0
end

def empty_result?(rows)
  rows = Array(rows)
  rows.empty? || rows.all? { |row| row.reject { |k, _| k == "time" }.values.all?(&:nil?) }
end

def format_values(rows)
  rows = Array(rows)
  return "[]" if rows.empty?

  text = format_all_values(rows)
  text.length > 70 ? "#{text[0, 67]}..." : text
end

def format_all_values(rows)
  if rows.size == 1 && rows.first.key?("value")
    return rows.first["value"].inspect
  end

  metric_keys = rows.first.keys - %w[time]
  if metric_keys.size == 1
    key = metric_keys.first
    vals = rows.map { |r| r[key].is_a?(Float) ? r[key].round(2) : r[key] }
    return "#{key}=#{vals.inspect}"
  end

  rows.inspect
end

def print_result(phase, label, body, match: nil)
  suffix = match.nil? ? "" : " match=#{match}"
  puts format(
    "%-6s %-34s latency_ms=%-7s used_metric=%-5s metric=%s rows=%d value=%s%s",
    phase,
    label,
    body["_latency_ms"].inspect,
    body["used_metric"].inspect,
    body["metric_name"].inspect,
    Array(body["data"]).size,
    format_values(body["data"]),
    suffix
  )
end

def speedup(before_ms, after_ms)
  return "n/a" if before_ms.nil? || after_ms.nil? || after_ms.to_f.zero?

  format("%.1fx", before_ms.to_f / after_ms.to_f)
end

def print_latency_summary(before, after, labels)
  puts "\n=== latency summary (before traces → after metrics) ==="
  puts format(
    "%-36s %10s %10s %10s %8s %8s %8s",
    "query",
    "before_ms",
    "after_ms",
    "delta_ms",
    "speedup",
    "metric?",
    "match"
  )
  puts "-" * 100

  before_total = 0.0
  after_total = 0.0

  labels.each do |label|
    b = before[label]
    a = after[label]
    next if b.nil? || a.nil?

    before_ms = b["_latency_ms"].to_f
    after_ms = a["_latency_ms"].to_f
    delta = (after_ms - before_ms).round(1)
    matched = rows_match?(b["data"], a["data"])
    used = a["used_metric"] ? "yes" : "no"

    before_total += before_ms
    after_total += after_ms

    puts format(
      "%-36s %10.1f %10.1f %10.1f %8s %8s %8s",
      label,
      before_ms,
      after_ms,
      delta,
      speedup(before_ms, after_ms),
      used,
      matched
    )
  end

  puts "-" * 100
  puts format(
    "%-36s %10.1f %10.1f %10.1f %8s",
    "TOTAL",
    before_total.round(1),
    after_total.round(1),
    (after_total - before_total).round(1),
    speedup(before_total, after_total)
  )
end

def run_query_set(phase, queries, before: nil)
  results = {}
  mismatches = []
  not_served = []

  queries.each do |label, sql|
    body = post_sql(sql)
    results[label] = body

    if before
      error = max_relative_error(before[label]["data"], body["data"])
      ok = error <= REL_TOL
      mismatches << "#{label} (max_rel_err=#{error.round(4)})" unless ok
      not_served << label unless body["used_metric"]
      print_result(phase, label, body, match: ok)
    else
      print_result(phase, label, body)
    end
  end

  [ results, mismatches, not_served ]
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

def histogram_metrics
  TraceToMetric.query_metrics.where(metric_type: "histogram")
end

def refresh_stale_watermarks!
  epoch = Time.utc(1970, 1, 1)
  watermark = latest_trace_watermark
  return unless watermark

  histogram_metrics.reject(&:backfill_finished?).each do |definition|
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
    unfinished_metrics = histogram_metrics.reject(&:backfill_finished?).map(&:name)

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
puts "time_buckets=#{TIME_BUCKETS.inspect} rel_tol=#{REL_TOL} abs_tol=#{ABS_TOL}"

count = span_count
puts "opentelemetry_traces rows: #{count}"
if count.zero?
  abort "No spans loaded. Import traces first, then re-run this script with bin/jobs running."
end

before = {}
after = {}
mismatches = []
not_served = []
ordered_labels = []

TIME_BUCKETS.each do |bucket|
  puts "\n--- per #{bucket} ---"
  queries = bucket_queries(bucket)
  bucket_before, = run_query_set("before", queries)
  before.merge!(bucket_before)
  ordered_labels.concat(queries.keys)
end

empty = ordered_labels.select { |label| empty_result?(before[label]["data"]) }
unless empty.empty?
  abort "\nEmpty results (nothing to verify):\n  #{empty.join("\n  ")}\n" \
        "Seed spans with duration_nano: bin/rails runner script/seed_histogram_metric_traces.rb"
end

wait_for_backfill_jobs!(POLL_SECONDS)

TIME_BUCKETS.each do |bucket|
  puts "\n--- per #{bucket} ---"
  queries = bucket_queries(bucket)
  bucket_after, bucket_mismatches, bucket_not_served = run_query_set("after", queries, before: before)
  after.merge!(bucket_after)
  mismatches.concat(bucket_mismatches)
  not_served.concat(bucket_not_served)
end

print_latency_summary(before, after, ordered_labels)

problems = []
problems << "Not served from a metric:\n  #{not_served.join("\n  ")}" unless not_served.empty?
problems << "Mismatch (rel_tol=#{REL_TOL}):\n  #{mismatches.join("\n  ")}" unless mismatches.empty?

if problems.empty?
  puts "\nOK: all #{ordered_labels.size} histogram queries use a metric and match within #{REL_TOL} after backfill."
else
  abort "\n#{problems.join("\n")}"
end
