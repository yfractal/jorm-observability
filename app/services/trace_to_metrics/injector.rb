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

    def initialize(trace, definition)
      @trace = trace
      @definition = definition
    end

    def call
      unless @definition.metric_type == "counter"
        Rails.logger.warn(
          "TraceToMetrics::Injector skipping unsupported metric_type=" \
          "#{@definition.metric_type.inspect} for #{@definition.name}"
        )
        return nil
      end

      upsert_counter!
      nil
    end

    private

    def upsert_counter!
      connection = ActiveRecord::Base.connection
      table = connection.quote_table_name(@definition.name)
      dimension_columns = @definition.dimension_columns
      dimension_values = resolve_dimensions

      columns = [ "bucket", *dimension_columns, "value", "created_at", "updated_at" ]
      quoted_columns = columns.map { |c| connection.quote_column_name(c) }.join(", ")

      now = Time.current
      binds = [
        self.class.bucket_for(@trace.timestamp),
        *dimension_columns.map { |c| dimension_values[c] },
        1,
        now,
        now
      ]
      placeholders = Array.new(binds.size, "?").join(", ")

      conflict_columns = [ "bucket", *dimension_columns ]
        .map { |c| connection.quote_column_name(c) }
        .join(", ")
      quoted_value = connection.quote_column_name("value")
      quoted_updated_at = connection.quote_column_name("updated_at")

      sql = <<~SQL.squish
        INSERT INTO #{table} (#{quoted_columns})
        VALUES (#{placeholders})
        ON CONFLICT (#{conflict_columns})
        DO UPDATE SET
          #{quoted_value} = #{table}.#{quoted_value} + 1,
          #{quoted_updated_at} = EXCLUDED.#{quoted_updated_at}
      SQL

      connection.exec_insert(
        ActiveRecord::Base.sanitize_sql_array([ sql, *binds ]),
        "TraceToMetrics::Injector Upsert"
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
