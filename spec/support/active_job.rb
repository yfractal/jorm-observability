RSpec.configure do |config|
  config.include ActiveJob::TestHelper

  config.around(:each, :no_transaction) do |example|
    self.use_transactional_tests = false
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    GreptimeHelpers.cleanup_greptime_data!
  end
end
