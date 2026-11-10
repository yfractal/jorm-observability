class Trace < ApplicationRecord
  self.primary_key = [ :trace_id, :span_id ]
  self.record_timestamps = false

  serialize :span_attributes, coder: JSON
  serialize :resource_attributes, coder: JSON
  serialize :span_events, coder: JSON
  serialize :span_links, coder: JSON

  after_create :enqueue_trace_created_job

  def span_attributes
    super || {}
  end

  def resource_attributes
    super || {}
  end

  def span_events
    super || []
  end

  def span_links
    super || []
  end

  private

  def enqueue_trace_created_job
    TraceCreatedJob.perform_later(trace_id, span_id)
  end
end
