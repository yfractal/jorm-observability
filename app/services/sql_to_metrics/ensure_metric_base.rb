# frozen_string_literal: true

module SqlToMetrics
  # Shared ensure flow: find-or-create definition, snapshot watermark, enqueue backfill.
  # Subclasses implement #build_spec and #create_definition!.
  class EnsureMetricBase
    Result = Struct.new(:metric_name, :created, :enqueued_backfill, keyword_init: true)

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
      raise NotImplementedError, "#{self.class}#build_spec"
    end

    def create_definition!(spec)
      raise NotImplementedError, "#{self.class}#create_definition!"
    end

    def snapshot_watermark!(definition)
      row = Greptime::Connection.exec_query(<<~SQL.squish, "#{self.class.name} Watermark").to_a.first
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
