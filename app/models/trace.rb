class Trace < ApplicationRecord
  after_create_commit :enqueue_trace_created_job

  private

  def enqueue_trace_created_job
    TraceCreatedJob.perform_later(id)
  end
end
