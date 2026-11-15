#!/usr/bin/env ruby
# frozen_string_literal: true

# Run dashboard gauge queries against POST /api/v1/sql, backfill the shared
# 1-minute gauge tables, then re-run and compare results. Fails if any query
# has used_metric=false or returns empty rows (seed with
# script/seed_gauge_metric_traces.rb).
#
#   bin/rails runner script/check_gauge_metric_backfill.rb
#
# Env:
#   SQL_API_URL   (default http://127.0.0.1:3000/api/v1/sql)
#   FROM_TS       (default 2026-10-22 14:00:00)
#   TO_TS         (default 2026-10-22 15:00:00)
#   POLL_SECONDS  (unused; backfill runs in-process)
#   TIME_BUCKETS  (optional comma list; default all Grafana $per values)
#   FLOAT_TOL     (default 1e-3 — absolute tolerance for float compares)

require "json"
require "net/http"
require "uri"

API_URL = ENV.fetch("SQL_API_URL", "http://127.0.0.1:3000/api/v1/sql")
FROM_TS = ENV.fetch("FROM_TS", "2026-10-22 14:00:00")
TO_TS = ENV.fetch("TO_TS", "2026-10-22 15:00:00")
POLL_SECONDS = ENV.fetch("POLL_SECONDS", "120").to_i
# Absolute floor (ms) plus relative slack — live ingest can leave one span
# on the raw side of a watermark race without changing the mean much.
FLOAT_TOL = ENV.fetch("FLOAT_TOL", "0.01").to_f
FLOAT_REL = ENV.fetch("FLOAT_REL", "0.0001").to_f
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

TOTAL_QUERIES = {
  "Average Response" => <<~SQL.squish,
    SELECT AVG(duration_nano) / 1e6 AS value
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND span_kind = 'SPAN_KIND_SERVER'
      AND "span_attributes.http.response.status_code" IS NOT NULL
  SQL
  "Average Database Response" => <<~SQL.squish,
    SELECT AVG(duration_nano) / 1e6 AS value
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND "span_attributes.db.system" IS NOT NULL
  SQL
  "Average Job Execution" => <<~SQL.squish
    SELECT AVG(duration_nano) / 1e6 AS value
    FROM opentelemetry_traces
    WHERE #{SHARED}
      AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
  SQL
}.freeze

def bucket_queries(per)
  {
    "Controller Action mean #{per}" => <<~SQL.squish,
      SELECT date_bin('#{per}', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
      FROM opentelemetry_traces
      WHERE #{SHARED}
        AND span_kind = 'SPAN_KIND_SERVER'
        AND "span_attributes.http.response.status_code" IS NOT NULL
      GROUP BY time ORDER BY time
    SQL
    "Database Query mean #{per}" => <<~SQL.squish,
      SELECT date_bin('#{per}', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
      FROM opentelemetry_traces
      WHERE #{SHARED}
        AND "span_attributes.db.system" IS NOT NULL
      GROUP BY time ORDER BY time
    SQL
    "ActiveJob mean #{per}" => <<~SQL.squish
      SELECT date_bin('#{per}', timestamp) AS time, AVG(duration_nano) / 1e6 AS mean
      FROM opentelemetry_traces
      WHERE #{SHARED}
        AND scope_name = 'OpenTelemetry::Instrumentation::ActiveJob'
      GROUP BY time ORDER BY time
    SQL
  }
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

def floatish?(value)
  value.is_a?(Numeric) || value.to_s.match?(/\A[-+]?\d+(\.\d+)?([eE][-+]?\d+)?\z/)
end

def values_close?(a, b)
  return true if a == b
  return false if a.nil? || b.nil?
  return false unless floatish?(a) && floatish?(b)

  left = a.to_f
  right = b.to_f
  delta = (left - right).abs
  return true if delta <= FLOAT_TOL

  scale = [ left.abs, right.abs ].max
  scale.positive? && (delta / scale) <= FLOAT_REL
end

def rows_match?(left, right)
  left = Array(left)
  right = Array(right)
  return false unless left.size == right.size

  left.zip(right).all? do |lrow, rrow|
    return false unless lrow.keys.sort == rrow.keys.sort

    lrow.all? { |key, value| values_close?(value, rrow[key]) }
  end
end

def format_values(rows)
  rows = Array(rows)
  return "[]" if rows.empty?

  if rows.size == 1 && rows.first.key?("value")
    return rows.first["value"].inspect
  end

  metric_keys = rows.first.keys - %w[time]
  if metric_keys.size == 1
    key = metric_keys.first
    vals = rows.map { |r| r[key] }
    return "#{key}=#{vals.inspect}"
  end

  rows.inspect
end

def print_result(phase, label, body, match: nil)
  suffix = match.nil? ? "" : " match=#{match}"
  puts format(
    "%-6s %-36s latency_ms=%-7s used_metric=%-5s metric=%s rows=%d value=%s%s",
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

def run_query_set(phase, queries, compare_raw: false)
  results = {}
  mismatches = []
  empty = []
  unused = []

  queries.each do |label, sql|
    body = post_sql(sql)
    results[label] = body
    rows = Array(body["data"])
    empty << label if rows.empty? || rows.all? { |r| r.values_at("value", "mean").compact.empty? }

    if compare_raw
      raw = SqlToMetrics::HybridQuery.call(sql, use_metric: false)
      ok = rows_match?(raw.rows, body["data"])
      unless ok
        mismatches << label
        puts "  mismatch detail raw=#{format_values(raw.rows)} metric=#{format_values(body["data"])}"
      end
      unused << label unless body["used_metric"]
      print_result(phase, label, body, match: ok)
    else
      print_result(phase, label, body)
    end
  end

  [ results, mismatches, empty, unused ]
end

def expected_gauge_names
  sqls = TOTAL_QUERIES.values + TIME_BUCKETS.flat_map { |bucket| bucket_queries(bucket).values }
  sqls.map { |sql| SqlToMetrics::Gauge::TableSpec.call(sql)[:name] }.uniq
end

def job_metric_name(job)
  Array(job.arguments["arguments"] || job.arguments[:arguments]).first
end

def span_count
  row = Greptime::Connection.exec_query("SELECT COUNT(*) AS c FROM opentelemetry_traces").to_a.first
  (row && (row["c"] || row.values.first)).to_i
end

def failed_backfill_executions(metric_names = nil)
  rel = SolidQueue::FailedExecution
    .joins(:job)
    .where(solid_queue_jobs: { class_name: "TraceToMetrics::BackfillJob" })
  return rel if metric_names.nil?

  rel.includes(:job).select { |execution| metric_names.include?(job_metric_name(execution.job)) }
end

def latest_trace_watermark
  row = Greptime::Connection.exec_query(<<~SQL.squish).to_a.first
    SELECT timestamp, trace_id, span_id
    FROM opentelemetry_traces
    ORDER BY timestamp DESC, trace_id DESC, span_id DESC
    LIMIT 1
  SQL
  return nil if row.nil?

  SqlToMetrics::Watermark.snapshot_from_row(row)
end

def refresh_stale_watermarks!(metric_names)
  epoch = Time.utc(1970, 1, 1)
  watermark = latest_trace_watermark
  return unless watermark

  TraceToMetric.where(name: metric_names).reject(&:backfill_finished?).each do |definition|
    next unless definition.backfill_through_timestamp.nil? ||
      definition.backfill_through_timestamp.utc <= epoch

    puts "Refresh watermark for #{definition.name}"
    definition.update_columns(watermark)
  end
end

def recover_failed_backfills!(metric_names)
  failed = failed_backfill_executions(metric_names)
  return if failed.empty?

  puts "Recovering #{failed.size} failed TraceToMetrics::BackfillJob execution(s)…"
  failed.each do |execution|
    job = execution.job
    metric_name = job_metric_name(job)
    puts "  retry #{metric_name.inspect}: #{execution.error.to_s[0, 120]}"
    execution.destroy!
    job.destroy! if job.finished_at.nil?
  end
end

def wait_for_backfill_jobs!(_timeout_seconds)
  names = expected_gauge_names
  puts "gauge metrics (shared 1-minute tables): #{names.size}"
  refresh_stale_watermarks!(names)
  recover_failed_backfills!(names)

  unfinished = TraceToMetric.where(name: names).reject(&:backfill_finished?)
  if unfinished.empty?
    puts "All gauge backfills already finished."
    return
  end

  unfinished.each do |definition|
    puts "Backfill #{definition.name}"
    TraceToMetrics::BackfillJob.perform_now(definition.name)
  end

  leftover = TraceToMetric.where(name: names).reject(&:backfill_finished?).map(&:name)
  abort "Backfill did not finish: #{leftover.inspect}" if leftover.any?

  puts "All gauge backfills finished."
end

puts "POST #{API_URL}"
puts "Range #{FROM_TS} .. #{TO_TS}"
puts "time_buckets=#{TIME_BUCKETS.inspect}"

count = span_count
puts "opentelemetry_traces rows: #{count}"
if count.zero?
  abort "No spans loaded. Run script/seed_gauge_metric_traces.rb first."
end

before = {}
after = {}
mismatches = []
unused_metrics = []
empty_queries = []
ordered_labels = []

puts "\n--- ensure metrics (before backfill) ---"
total_before, _, total_empty, = run_query_set("before", TOTAL_QUERIES)
before.merge!(total_before)
empty_queries.concat(total_empty)
ordered_labels.concat(TOTAL_QUERIES.keys)

TIME_BUCKETS.each do |bucket|
  puts "\n--- per #{bucket} ---"
  queries = bucket_queries(bucket)
  bucket_before, _, bucket_empty, = run_query_set("before", queries)
  before.merge!(bucket_before)
  empty_queries.concat(bucket_empty)
  ordered_labels.concat(queries.keys)
end

if empty_queries.any?
  abort <<~MSG

    Empty gauge query result(s): #{empty_queries.join(', ')}
    Seed spans first:
      bin/rails runner script/seed_gauge_metric_traces.rb
    Then re-run this script with bin/jobs running.
  MSG
end

wait_for_backfill_jobs!(POLL_SECONDS)

# Compare metric vs raw at the same moment so live ingest cannot drift the check.
puts "\n--- totals (metric vs raw) ---"
total_after, total_mismatches, _, total_unused = run_query_set("after", TOTAL_QUERIES, compare_raw: true)
after.merge!(total_after)
mismatches.concat(total_mismatches)
unused_metrics.concat(total_unused)

TIME_BUCKETS.each do |bucket|
  puts "\n--- per #{bucket} ---"
  queries = bucket_queries(bucket)
  bucket_after, bucket_mismatches, _, bucket_unused = run_query_set("after", queries, compare_raw: true)
  after.merge!(bucket_after)
  mismatches.concat(bucket_mismatches)
  unused_metrics.concat(bucket_unused)
end

print_latency_summary(before, after, ordered_labels)

errors = []
errors << "Mismatch (metric vs raw): #{mismatches.join(', ')}" if mismatches.any?
errors << "used_metric=false: #{unused_metrics.join(', ')}" if unused_metrics.any?

if errors.empty?
  puts "\nOK: all gauge queries used_metric=true and match raw at the same moment."
else
  abort "\n#{errors.join("\n")}"
end
