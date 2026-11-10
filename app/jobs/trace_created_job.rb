class TraceCreatedJob < ApplicationJob
  queue_as :default

  def perform(trace_record_id)
    trace = Trace.find_by(id: trace_record_id)
    return unless trace

    definition = TraceToMetric.for_span_name(trace.span_name)
    return unless definition

    # TODO: inject trace into the relative metric table
    TraceToMetrics::Injector.call(trace, definition)
  end
end
