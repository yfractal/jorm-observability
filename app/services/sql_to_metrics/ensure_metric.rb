module SqlToMetrics
  class EnsureMetric
    Result = Struct.new(:metric_name, :created, :enqueued_backfill, keyword_init: true)

    def initialize(sql)
      @sql = sql.to_s
    end

    def call
      if !is_a?(HistogramMetrics::EnsureMetric) && HistogramMetrics.histogram_sql?(@sql)
        return HistogramMetrics::EnsureMetric.new(@sql).call
      end
      return Gauge::EnsureMetric.new(@sql).call if Gauge::Mapper.gauge_sql?(@sql)

      spec = build_spec
      existing = TraceToMetric.find_by(name: spec[:name])
      if existing
        return Result.new(metric_name: existing.name, created: false, enqueued_backfill: false)
      end

      definition = create_definition!(spec)
      snapshot_watermark!(definition)
      TraceToMetrics::BackfillJob.perform_later(definition.name)

      Result.new(metric_name: definition.name, created: true, enqueued_backfill: true)
    rescue UnsupportedError, ParseError
      Result.new(metric_name: nil, created: false, enqueued_backfill: false)
    end

    private

    def build_spec
      TableSpec.call(@sql)
    end

    def create_definition!(spec)
      TraceToMetric.create!(
        name: spec[:name],
        span_name: TraceToMetric::QUERY_SPAN_NAME,
        metric_type: "counter",
        dimensions: Array(spec[:dimensions]),
        filters: Array(spec[:filters]),
        bucket_interval: spec[:bucket_interval]
      )
    end

    def snapshot_watermark!(definition)
      row = Greptime::Connection.exec_query(<<~SQL.squish, "SqlToMetrics::EnsureMetric Watermark").to_a.first
        SELECT timestamp, trace_id, span_id
        FROM opentelemetry_traces
        ORDER BY timestamp DESC, trace_id DESC, span_id DESC
        LIMIT 1
      SQL

      if row
        # pg/Greptime may truncate sub-ms on read; bump 1ms and max ids so the
        # latest span (and any peers in that truncated tick) stay in backfill.
        definition.update_columns(Watermark.snapshot_from_row(row))
      else
        # No traces yet: watermark at epoch so every future span is after it.
        definition.update_columns(
          backfill_through_timestamp: Time.utc(1970, 1, 1),
          backfill_through_trace_id: "",
          backfill_through_span_id: ""
        )
      end
    end
  end
end
