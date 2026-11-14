module TraceToMetrics
  class BackfillJob < ApplicationJob
    queue_as :default

    def perform(metric_name)
      definition = TraceToMetric.find_by(name: metric_name)
      return unless definition&.query_metric?
      return if definition.backfill_finished?
      return unless definition.watermark_ready?

      insert_aggregated!(definition)
      definition.update_columns(backfill_finished_at: Time.now.utc)
    end

    private

    def insert_aggregated!(definition)
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
      where = watermark_and_filters_sql(definition)

      connection.execute(<<~SQL.squish)
        INSERT INTO #{table} (#{insert_cols.join(', ')})
        SELECT #{select_list}
        FROM #{source}
        WHERE #{where}
        GROUP BY #{group_list}
      SQL
    end

    def watermark_and_filters_sql(definition)
      connection = Greptime::Connection
      ts = definition.backfill_through_timestamp.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
      parts = [
        "(timestamp < #{connection.quote(ts)}" \
          " OR (timestamp = #{connection.quote(ts)}" \
          " AND trace_id < #{connection.quote(definition.backfill_through_trace_id.to_s)})" \
          " OR (timestamp = #{connection.quote(ts)}" \
          " AND trace_id = #{connection.quote(definition.backfill_through_trace_id.to_s)}" \
          " AND span_id <= #{connection.quote(definition.backfill_through_span_id.to_s)}))"
      ]

      Array(definition.filters).each do |filter|
        column = filter["column"] || filter[:column]
        op = filter["op"] || filter[:op]
        value = filter.key?("value") ? filter["value"] : filter[:value]
        quoted = connection.quote_column_name(column)
        parts <<
          case op
          when "IS NULL" then "#{quoted} IS NULL"
          when "IS NOT NULL" then "#{quoted} IS NOT NULL"
          when "=" then "#{quoted} = #{connection.quote(value.to_s)}"
          else "TRUE"
          end
      end

      parts.join(" AND ")
    end
  end
end
