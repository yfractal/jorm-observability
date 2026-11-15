module TraceToMetrics
  class Injector
    CORE_DIMENSIONS = %w[
      service_name
      span_kind
      span_status_code
      span_name
      scope_name
    ].freeze

    def self.call(trace, definition)
      new(trace, definition).call
    end

    def self.bucket_for(timestamp)
      timestamp.change(usec: 0)
    end

    def self.summed_rows(table_name, dimension_columns = nil)
      connection = Greptime::Connection
      table = connection.quote_table_name(table_name)
      dims = Array(dimension_columns)
      if dims.empty?
        connection.exec_query(
          "SELECT bucket, SUM(value) AS value FROM #{table} GROUP BY bucket ORDER BY bucket",
          "TraceToMetrics::Injector Sum"
        ).to_a
      else
        quoted_dims = dims.map { |c| connection.quote_column_name(c) }
        select_list = [ "bucket", *quoted_dims, "SUM(value) AS value" ].join(", ")
        group_list = [ "bucket", *quoted_dims ].join(", ")
        connection.exec_query(
          "SELECT #{select_list} FROM #{table} GROUP BY #{group_list} ORDER BY bucket",
          "TraceToMetrics::Injector Sum"
        ).to_a
      end
    end

    def initialize(trace, definition)
      @trace = trace
      @definition = definition
    end

    def call
      case @definition.metric_type
      when "counter"
        append_counter!
      when "gauge"
        Gauge::Injector.call(@trace, @definition)
      else
        Rails.logger.warn(
          "TraceToMetrics::Injector skipping unsupported metric_type=" \
          "#{@definition.metric_type.inspect} for #{@definition.name}"
        )
      end
      nil
    end

    private

    def append_counter!
      connection = Greptime::Connection
      table = connection.quote_table_name(@definition.name)
      dimension_columns = @definition.dimension_columns
      dimension_values = resolve_dimensions

      columns = [ "bucket", *dimension_columns, "value" ]
      quoted_columns = columns.map { |c| connection.quote_column_name(c) }.join(", ")

      binds = [
        self.class.bucket_for(@trace.timestamp),
        *dimension_columns.map { |c| dimension_values[c] },
        1
      ]
      placeholders = Array.new(binds.size, "?").join(", ")

      sql = <<~SQL.squish
        INSERT INTO #{table} (#{quoted_columns})
        VALUES (#{placeholders})
      SQL

      connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([ sql, *binds ]),
        "TraceToMetrics::Injector Append"
      )
    end

    def resolve_dimensions
      Array(@definition.dimensions).each_with_object({}) do |raw_name, memo|
        column = TraceToMetric.sanitize_dimension(raw_name)
        memo[column] = stringify_dimension_value(lookup_dimension(raw_name))
      end
    end

    def lookup_dimension(name)
      key = name.to_s

      span_attrs = @trace.span_attributes || {}
      return span_attrs[key] if span_attrs.key?(key)

      resource_attrs = @trace.resource_attributes || {}
      return resource_attrs[key] if resource_attrs.key?(key)

      return @trace.public_send(key) if CORE_DIMENSIONS.include?(key) && @trace.respond_to?(key)

      nil
    end

    def stringify_dimension_value(value)
      case value
      when nil then ""
      when String then value
      when Hash, Array then value.to_json
      else value.to_s
      end
    end
  end
end
