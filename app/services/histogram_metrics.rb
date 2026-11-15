require "pg_query"

# Histogram metrics: pre-aggregated UDDSketch states per (bucket, dimensions) that
# serve `approx_percentile_cont(col, q)` dashboard queries, the same way counter
# metrics serve `COUNT(*)`. Everything histogram-specific lives under this
# namespace; the counter pipeline only dispatches into it.
#
#   Spec          SQL -> metric definition (name, filters, dimensions, value column)
#   Table         DDL for the sketch table
#   EnsureMetric  creates the definition + watermark + enqueues the backfill
#   Backfill      one INSERT ... SELECT uddsketch_state(...) chunk for BackfillJob
#   Injector      appends a live span's sketch row
#   QueryRewriter metric segment + raw segment, merged and re-binned
module HistogramMetrics
  PERCENTILE_FUNC = "approx_percentile_cont".freeze
  SKETCH_COLUMN = "sketch".freeze
  # GreptimeDB uddsketch_state/merge parameters: states are only mergeable when
  # these match, so they are fixed for every histogram metric.
  SKETCH_BUCKETS = 128
  SKETCH_ERROR_RATE = 0.01

  module_function

  # True when the statement calls approx_percentile_cont anywhere.
  def histogram_sql?(sql)
    PgQuery.parse(sql.to_s).functions.any? { |name| name.to_s.casecmp?(PERCENTILE_FUNC) }
  rescue PgQuery::ParseError
    false
  end

  def sketch_state_sql(value_sql)
    "uddsketch_state(#{SKETCH_BUCKETS}, #{SKETCH_ERROR_RATE}, #{value_sql})"
  end

  def sketch_merge_sql(sketch_sql)
    "uddsketch_merge(#{SKETCH_BUCKETS}, #{SKETCH_ERROR_RATE}, #{sketch_sql})"
  end

  def sketch_calc_sql(quantile, merged_sketch_sql)
    "uddsketch_calc(#{quantile}, #{merged_sketch_sql})"
  end
end
