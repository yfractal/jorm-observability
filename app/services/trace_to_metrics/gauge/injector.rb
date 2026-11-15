# frozen_string_literal: true

module TraceToMetrics
  module Gauge
    class Injector
      CORE_DIMENSIONS = TraceToMetrics::Injector::CORE_DIMENSIONS

      def self.call(trace, definition)
        new(trace, definition).call
      end

      def self.bucket_for(timestamp)
        TraceToMetrics::Injector.bucket_for(timestamp)
      end

      def self.summed_rows(table_name, dimension_columns = nil)
        connection = Greptime::Connection
        table = connection.quote_table_name(table_name)
        dims = Array(dimension_columns)
        select_dims = dims.map { |c| connection.quote_column_name(c) }
        select_list = [
          "bucket",
          *select_dims,
          "SUM(value_sum) AS value_sum",
          "SUM(value_count) AS value_count"
        ].join(", ")
        group_list = [ "bucket", *select_dims ].join(", ")
        connection.exec_query(
          "SELECT #{select_list} FROM #{table} GROUP BY #{group_list} ORDER BY bucket",
          "TraceToMetrics::Gauge::Injector Sum"
        ).to_a
      end

      def initialize(trace, definition)
        @trace = trace
        @definition = definition
      end

      def call
        value = resolve_value
        return nil if value.nil?

        append_gauge!(value)
        nil
      end

      private

      def append_gauge!(value)
        connection = Greptime::Connection
        table = connection.quote_table_name(@definition.name)
        dimension_columns = @definition.dimension_columns
        dimension_values = resolve_dimensions

        columns = [ "bucket", *dimension_columns, "value_sum", "value_count" ]
        quoted_columns = columns.map { |c| connection.quote_column_name(c) }.join(", ")

        binds = [
          self.class.bucket_for(@trace.timestamp),
          *dimension_columns.map { |c| dimension_values[c] },
          value,
          1
        ]
        placeholders = Array.new(binds.size, "?").join(", ")

        sql = <<~SQL.squish
          INSERT INTO #{table} (#{quoted_columns})
          VALUES (#{placeholders})
        SQL

        connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([ sql, *binds ]),
          "TraceToMetrics::Gauge::Injector Append"
        )
      end

      def resolve_value
        column = SqlToMetrics::Gauge::TableSpec.value_column_from_name(@definition.name)
        return nil if column.blank?

        raw = lookup_dimension(column)
        return nil if raw.nil? || raw == ""

        Float(raw)
      rescue ArgumentError, TypeError
        nil
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
        return span_attrs[key.delete_prefix("span_attributes.")] if key.start_with?("span_attributes.") &&
          span_attrs.key?(key.delete_prefix("span_attributes."))

        resource_attrs = @trace.resource_attributes || {}
        return resource_attrs[key] if resource_attrs.key?(key)
        return resource_attrs[key.delete_prefix("resource_attributes.")] if key.start_with?("resource_attributes.") &&
          resource_attrs.key?(key.delete_prefix("resource_attributes."))

        return @trace.public_send(key) if CORE_DIMENSIONS.include?(key) && @trace.respond_to?(key)
        return @trace.public_send(key) if @trace.respond_to?(key) && !CORE_DIMENSIONS.include?(key) &&
          %w[duration_nano timestamp].include?(key)

        # duration_nano and similar core numeric fields
        return @trace.public_send(key) if @trace.respond_to?(key)

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
end
