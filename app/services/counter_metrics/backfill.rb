# frozen_string_literal: true

module CounterMetrics
  # One BackfillJob chunk for a counter metric: COUNT(*) per (bucket, dimensions).
  module Backfill
    module_function

    # `where_sql` is the job's watermark + filters + chunk time range predicate.
    def insert_chunk!(definition, where_sql:)
      connection = Greptime::Connection
      table = connection.quote_table_name(definition.name)
      source = connection.quote_table_name("opentelemetry_traces")
      interval = definition.bucket_interval.presence || "1 minute"
      dimensions = Array(definition.dimensions)
      dim_cols = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
      quoted_dims = dimensions.map { |d| connection.quote_column_name(d) }
      quoted_dim_aliases = dim_cols.map { |c| connection.quote_column_name(c) }

      select_dims =
        if dimensions.empty?
          []
        else
          dimensions.each_with_index.map do |raw, i|
            "#{connection.quote_column_name(raw)} AS #{quoted_dim_aliases[i]}"
          end
        end

      insert_cols = [ "bucket", *dim_cols, "value" ].map { |c| connection.quote_column_name(c) }
      select_list = [
        "date_bin(#{connection.quote(interval)}, timestamp) AS bucket",
        *select_dims,
        "COUNT(*) AS value"
      ].join(", ")

      group_list = [ "bucket", *quoted_dims ].join(", ")

      connection.execute(<<~SQL.squish)
        INSERT INTO #{table} (#{insert_cols.join(', ')})
        SELECT #{select_list}
        FROM #{source}
        WHERE #{where_sql}
        GROUP BY #{group_list}
      SQL
    end
  end
end
