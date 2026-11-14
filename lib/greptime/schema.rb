module Greptime
  module Schema
    SCHEMA_DIR = Rails.root.join("db/greptime")

    TRACE_TO_METRICS_COLUMNS = {
      "filters" => "STRING",
      "bucket_interval" => "STRING",
      "backfill_through_timestamp" => "TIMESTAMP",
      "backfill_through_trace_id" => "STRING",
      "backfill_through_span_id" => "STRING",
      "backfill_finished_at" => "TIMESTAMP"
    }.freeze

    module_function

    def load!
      connection = ActiveRecord::Base.connection
      Dir[SCHEMA_DIR.join("*.sql")].sort.each do |path|
        sql = File.read(path)
        connection.execute(sql)
      end
      migrate_trace_to_metrics_columns!
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
