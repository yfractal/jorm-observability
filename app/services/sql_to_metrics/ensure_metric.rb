module SqlToMetrics
  class EnsureMetric
    Result = Struct.new(:metric_name, :created, :enqueued_backfill, keyword_init: true)

    def self.call(sql)
      klass = HistogramMetrics.histogram_sql?(sql) ? HistogramMetrics::EnsureMetric : self
      klass.new(sql).call
    end

    def initialize(sql)
      @sql = sql.to_s
    end

    def call
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
        definition.update_columns(
          backfill_through_timestamp: parse_time(row["timestamp"] || row.values[0]),
          backfill_through_trace_id: (row["trace_id"] || row.values[1]).to_s,
          backfill_through_span_id: (row["span_id"] || row.values[2]).to_s
        )
      else
        # No traces yet: watermark at epoch so every future span is after it.
        definition.update_columns(
          backfill_through_timestamp: Time.utc(1970, 1, 1),
          backfill_through_trace_id: "",
          backfill_through_span_id: ""
        )
      end
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
