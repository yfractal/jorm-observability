# Creates the isolated Greptime test catalog before Rails connects.
# Loaded from rails_helper before config/environment.
require "json"
require "net/http"
require "uri"

module GreptimeTestDatabase
  module_function

  DEFAULT_NAME = "jorm_observability_test"

  def ensure!
    db = test_database_name
    return if db.nil? || db.empty? || db == "public"

    http = ENV.fetch(
      "GREPTIME_HTTP",
      "http://#{ENV.fetch('GREPTIME_HOST', '127.0.0.1')}:4000"
    )
    uri = URI("#{http}/v1/sql")
    uri.query = URI.encode_www_form(db: "public", sql: "CREATE DATABASE IF NOT EXISTS #{db}")
    response = Net::HTTP.get_response(uri)
    body = JSON.parse(response.body)
    raise "Greptime CREATE DATABASE #{db} failed: #{body['error']}" if body["error"]
  end

  def test_database_name
    ENV.fetch("GREPTIME_TEST_DATABASE", DEFAULT_NAME)
  end
end
