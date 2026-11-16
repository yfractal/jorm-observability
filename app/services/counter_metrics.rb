# frozen_string_literal: true

# Counter metrics: pre-aggregated COUNT(*) per (bucket, dimensions) that serve
# dashboard COUNT queries. Layout mirrors HistogramMetrics / GaugeMetrics.
#
#   Spec            SQL -> metric definition (name, filters, dimensions)
#   Table           DDL for the counter table
#   EnsureMetric    creates the definition + watermark + enqueues the backfill
#   Backfill        one INSERT ... SELECT COUNT(*) chunk for BackfillJob
#   Injector        appends a live span's counter row
#   QueryRewriter   metric segment + raw segment, merged and re-binned
module CounterMetrics
  module_function

  # True when the statement calls COUNT anywhere.
  def counter_sql?(sql)
    sql.to_s.match?(/\bcount\s*\(/i)
  end
end
