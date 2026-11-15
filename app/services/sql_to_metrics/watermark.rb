# frozen_string_literal: true

module SqlToMetrics
  # Snapshot the latest opentelemetry_traces row as a backfill watermark.
  # Greptime/pg often truncates sub-millisecond timestamps on read; bumping by
  # 1ms with max tie-break ids keeps the true latest span inside backfill.
  module Watermark
    module_function

    MAX_TRACE_ID = ("f" * 32).freeze
    MAX_SPAN_ID = ("f" * 16).freeze
    PRECISION_SLACK = Rational(1, 1000) # 1ms

    def snapshot_from_row(row)
      ts = parse_time(row["timestamp"] || row.values[0])
      {
        backfill_through_timestamp: Time.at(ts.to_r + PRECISION_SLACK).utc,
        backfill_through_trace_id: MAX_TRACE_ID,
        backfill_through_span_id: MAX_SPAN_ID,
        backfill_finished_at: nil
      }
    end

    def parse_time(value)
      case value
      when Time then value.utc
      when DateTime then value.to_time.utc
      else Time.parse(value.to_s).utc
      end
    end
  end
end
