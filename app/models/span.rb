class Span < ApplicationRecord
  after_create_commit :enqueue_span_created_job

  private

  def enqueue_span_created_job
    SpanCreatedJob.perform_later(id)
  end
end
