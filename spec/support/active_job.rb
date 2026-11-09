RSpec.configure do |config|
  config.include ActiveJob::TestHelper

  config.around(:each, :no_transaction) do |example|
    self.use_transactional_tests = false
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs

    SpanToMetric.find_each do |definition|
      conn = ActiveRecord::Base.connection
      conn.drop_table(definition.name, if_exists: true)
    end
    SpanToMetric.delete_all
    Span.delete_all
  end
end
