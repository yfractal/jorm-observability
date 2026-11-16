# frozen_string_literal: true

# Gauge metrics: pre-aggregated AVG via append-only value_sum / value_count that
# serve dashboard AVG queries. Layout mirrors HistogramMetrics / CounterMetrics.
#
#   Spec            SQL -> metric definition (name, filters, value column, scale)
#   Mapper          AVG(col) [/ const] SQL shape detection and mapping
#   Table           DDL for the gauge table
#   EnsureMetric    creates the definition + watermark + enqueues the backfill
#   Backfill        one INSERT ... SELECT SUM/COUNT chunk for BackfillJob
#   Injector        appends a live span's sum/count row
#   QueryRewriter   metric segment + raw segment, mean re-aggregated
module GaugeMetrics
end
