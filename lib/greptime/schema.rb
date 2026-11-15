require "json"
require "net/http"
require "uri"

module Greptime
  module Schema
    SCHEMA_DIR = Rails.root.join("db/greptime")

    TRACE_TO_METRICS_COLUMNS = {
      "filters" => "STRING",
      "bucket_interval" => "STRING",
      "backfill_through_timestamp" => "TIMESTAMP",
      "backfill_through_trace_id" => "STRING",
      "backfill_through_span_id" => "STRING",
      "backfill_finished_at" => "TIMESTAMP",
      "value_column" => "STRING"
    }.freeze

    module_function

    def load!
      ensure_current_database!
      connection = ActiveRecord::Base.connection
      Dir[SCHEMA_DIR.join("*.sql")].sort.each do |path|
        sql = File.read(path)
        connection.execute(sql)
      end
      migrate_trace_to_metrics_columns!
    end

    def ensure_current_database!
      db = ActiveRecord::Base.connection_db_config.configuration_hash[:database].to_s
      return if db.blank? || db == "public"

      ensure_database!(db)
    end

    def ensure_database!(database)
      http = ENV.fetch(
        "GREPTIME_HTTP",
        "http://#{ENV.fetch('GREPTIME_HOST', '127.0.0.1')}:4000"
      )
      # CREATE DATABASE is catalog-level; run against the default public catalog.
      uri = URI("#{http}/v1/sql")
      uri.query = URI.encode_www_form(db: "public", sql: "CREATE DATABASE IF NOT EXISTS #{database}")
      response = Net::HTTP.get_response(uri)
      body = JSON.parse(response.body)
      raise "Greptime CREATE DATABASE #{database} failed: #{body['error']}" if body["error"]
    end

    def migrate_trace_to_metrics_columns!
      return unless Greptime::Connection.table_exists?("trace_to_metrics")

      existing = Greptime::Connection.column_names("trace_to_metrics")
      table = Greptime::Connection.quote_table_name("trace_to_metrics")

      TRACE_TO_METRICS_COLUMNS.each do |column, type|
        next if existing.include?(column)

        quoted = Greptime::Connection.quote_column_name(column)
        Greptime::Connection.execute(
          "ALTER TABLE #{table} ADD COLUMN #{quoted} #{type}".squish
        )
      end
    end
  end
end
