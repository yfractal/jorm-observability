# This file is copied to spec/ when you run 'rails generate rspec:install'
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"

# Create the isolated Greptime test catalog before Active Record connects.
require_relative "support/greptime_test_database"
GreptimeTestDatabase.ensure!

require_relative "../config/environment"
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }

# GreptimeDB is not managed by Active Record schema dumps/migrations.
begin
  Greptime::Schema.load!
  db = ActiveRecord::Base.connection_db_config.configuration_hash[:database]
  if db.to_s == "public"
    abort "Refusing to run specs against Greptime database `public`. Set GREPTIME_TEST_DATABASE (default: jorm_observability_test)."
  end
rescue StandardError => e
  warn "GreptimeDB schema load failed: #{e.class}: #{e.message}"
  warn "Start Greptime with `docker compose up -d greptimedb` then re-run specs."
  raise
end

RSpec.configure do |config|
  config.fixture_paths = [
    Rails.root.join("spec/fixtures")
  ]

  # GreptimeDB does not provide Postgres-compatible transactional rollback for fixtures.
  config.use_transactional_fixtures = false
  config.global_fixtures = nil

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.after(:each) do
    GreptimeHelpers.cleanup_greptime_data!
  end
end
