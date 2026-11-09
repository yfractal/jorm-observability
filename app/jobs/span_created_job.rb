class SpanCreatedJob < ApplicationJob
  queue_as :default

  def perform(span_id)
    span = Span.find_by(id: span_id)
    return unless span

    definition = SpanToMetric.for_span_name(span.span_name)
    return unless definition

    # TODO: inject span into the relative metric table
    SpanToMetrics::Injector.call(span, definition)
  end
end
