class OpentelemetryTraceCreatedJob < ApplicationJob
  queue_as :default

  class WatermarkNotReady < StandardError; end

  retry_on WatermarkNotReady, wait: 2.seconds, attempts: 10

  def perform(trace_id, span_id)
    trace = OpentelemetryTrace.find_by(trace_id: trace_id, span_id: span_id)
    return unless trace

    # Wait until every query metric has a watermark so we never append a span
    # that the backfill also owns, and never double-append a span-name metric on retry.
    ensure_query_watermarks_ready!

    inject_span_name_metric!(trace)
    inject_query_metrics!(trace)
  end

  private

  def ensure_query_watermarks_ready!
    pending = TraceToMetric.query_metrics.reject(&:watermark_ready?)
    return if pending.empty?

    raise WatermarkNotReady, "watermark not ready for #{pending.map(&:name).join(', ')}"
  end

  def inject_span_name_metric!(trace)
    definition = TraceToMetric.for_span_name(trace.span_name)
    return unless definition

    TraceToMetrics::Injector.call(trace, definition)
  end

  def inject_query_metrics!(trace)
    TraceToMetric.query_metrics.to_a.each do |definition|
      next unless definition.after_watermark?(trace)
      next unless definition.matches_trace?(trace)

      TraceToMetrics::Injector.call(trace, definition)
    end
  end
end
