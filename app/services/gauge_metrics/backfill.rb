# frozen_string_literal: true

module GaugeMetrics
  # Gauge-specific backfill INSERT (SUM/COUNT of the value column).
  # Chunking / watermark / filter SQL stay in TraceToMetrics::BackfillJob.
  class Backfill
    def self.insert_aggregated!(definition, from:, to:, watermark_and_filters_sql:)
      new(definition, from: from, to: to, watermark_and_filters_sql: watermark_and_filters_sql).insert!
    end

    def initialize(definition, from:, to:, watermark_and_filters_sql:)
      @definition = definition
      @from = from
      @to = to
      @watermark_and_filters_sql = watermark_and_filters_sql
    end

    def insert!
      connection = Greptime::Connection
      table = connection.quote_table_name(@definition.name)
      source = connection.quote_table_name("opentelemetry_traces")
      interval = @definition.bucket_interval.presence || "1 minute"
      dimensions = Array(@definition.dimensions)
      dim_cols = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
      quoted_dims = dimensions.map { |d| connection.quote_column_name(d) }
      quoted_dim_aliases = dim_cols.map { |c| connection.quote_column_name(c) }
      value_column = GaugeMetrics::Spec.value_column_from_name(@definition.name)
      raise ArgumentError, "cannot parse value column from #{@definition.name}" if value_column.blank?

      quoted_value = connection.quote_column_name(value_column)

      select_dims =
        if dimensions.empty?
          []
        else
          dimensions.each_with_index.map do |raw, i|
            "#{connection.quote_column_name(raw)} AS #{quoted_dim_aliases[i]}"
          end
        end

      insert_cols = [ "bucket", *dim_cols, "value_sum", "value_count" ].map { |c|
        connection.quote_column_name(c)
      }
      select_list = [
        "date_bin(#{connection.quote(interval)}, timestamp) AS bucket",
        *select_dims,
        "SUM(#{quoted_value}) AS value_sum",
        "COUNT(#{quoted_value}) AS value_count"
      ].join(", ")

      group_list = [ "bucket", *quoted_dims ].join(", ")
      where = [
        @watermark_and_filters_sql,
        "timestamp >= #{connection.quote(@from.utc.strftime('%Y-%m-%d %H:%M:%S.%6N'))}",
        "timestamp < #{connection.quote(@to.utc.strftime('%Y-%m-%d %H:%M:%S.%6N'))}",
        "#{quoted_value} IS NOT NULL"
      ].join(" AND ")

      connection.execute(<<~SQL.squish)
        INSERT INTO #{table} (#{insert_cols.join(', ')})
        SELECT #{select_list}
        FROM #{source}
        WHERE #{where}
        GROUP BY #{group_list}
      SQL
    end
  end
end
