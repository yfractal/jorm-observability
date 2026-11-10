class TraceCreatedJob < ApplicationJob
  queue_as :default

  def perform(trace_id, span_id)
    trace = Trace.find_by(trace_id: trace_id, span_id: span_id)
    return unless trace

    definition = TraceToMetric.for_span_name(trace.span_name)
    return unless definition

    TraceToMetrics::Injector.call(trace, definition)
  end
end
