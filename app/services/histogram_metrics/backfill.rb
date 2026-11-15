module HistogramMetrics
  # One BackfillJob chunk for a histogram metric: a sketch per (bucket, dimensions).
  module Backfill
    module_function

    # `where_sql` is the job's watermark + filters + chunk time range predicate.
    def insert_chunk!(definition, where_sql:)
      connection = Greptime::Connection
      interval = definition.bucket_interval.presence || "1 minute"
      dimensions = Array(definition.dimensions)
      dim_cols = definition.dimension_columns
      value_column = connection.quote_column_name(definition.value_column)

      insert_cols = [ "bucket", *dim_cols, SKETCH_COLUMN ].map { |c| connection.quote_column_name(c) }
      select_list = [
        "date_bin(#{connection.quote(interval)}, timestamp) AS bucket",
        *dimensions.each_with_index.map { |raw, i| "#{connection.quote_column_name(raw)} AS #{connection.quote_column_name(dim_cols[i])}" },
        "#{HistogramMetrics.sketch_state_sql(value_column)} AS #{connection.quote_column_name(SKETCH_COLUMN)}"
      ].join(", ")
      group_list = [ "bucket", *dimensions.map { |d| connection.quote_column_name(d) } ].join(", ")

      connection.execute(<<~SQL.squish)
        INSERT INTO #{connection.quote_table_name(definition.name)} (#{insert_cols.join(', ')})
        SELECT #{select_list}
        FROM #{connection.quote_table_name('opentelemetry_traces')}
        WHERE #{where_sql} AND #{value_column} IS NOT NULL
        GROUP BY #{group_list}
      SQL
    end
  end
end
