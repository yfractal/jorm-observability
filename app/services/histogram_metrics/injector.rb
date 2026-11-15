module HistogramMetrics
  # Appends a sketch holding one live span's value. Reuses the counter injector's
  # dimension resolution; the value is read back from the span row so any
  # numeric column works.
  class Injector < TraceToMetrics::Injector
    def call
      value_column = @definition.value_column
      return nil if value_column.blank?

      connection = Greptime::Connection
      dimension_columns = @definition.dimension_columns
      dimension_values = resolve_dimensions
      bucket = SqlToMetrics::Interval.floor_bucket(@trace.timestamp.utc, @definition.bucket_interval.presence || "1 minute")

      columns = [ "bucket", *dimension_columns, SKETCH_COLUMN ].map { |c| connection.quote_column_name(c) }
      literals = [
        connection.quote(bucket.strftime("%Y-%m-%d %H:%M:%S.%6N")),
        *dimension_columns.map { |c| connection.quote(dimension_values[c]) },
        HistogramMetrics.sketch_state_sql(connection.quote_column_name(value_column))
      ]

      connection.execute(<<~SQL.squish)
        INSERT INTO #{connection.quote_table_name(@definition.name)} (#{columns.join(', ')})
        SELECT #{literals.join(', ')}
        FROM #{connection.quote_table_name('opentelemetry_traces')}
        WHERE trace_id = #{connection.quote(@trace.trace_id.to_s)}
          AND span_id = #{connection.quote(@trace.span_id.to_s)}
          AND #{connection.quote_column_name(value_column)} IS NOT NULL
      SQL
      nil
    end
  end
end
