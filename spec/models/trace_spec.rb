require "rails_helper"

RSpec.describe Trace, type: :model do
  it "enqueues TraceCreatedJob after create commit", :no_transaction do
    expect {
      described_class.create!(
        timestamp: Time.current,
        span_name: "http",
        trace_id: "t1",
        span_id: "s1"
      )
    }.to have_enqueued_job(TraceCreatedJob)
  end
end
