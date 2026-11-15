# frozen_string_literal: true

module SqlToMetrics
  module Gauge
    class TableSpec
      def self.call(sql)
        new(sql).call
      end

      def initialize(sql)
        @sql = sql
      end

      def call
        mapped = Mapper.call(@sql)
        validate!(mapped)

        dimensions = Array(mapped[:dimensions])
        dimension_columns = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
        time_bucket = mapped[:time_bucket]
        filters = Array(mapped[:filters])
        avg = avg_target(mapped[:res_targets])
        value_column = avg[:column]
        scale = avg[:scale]

        name_interval = time_bucket&.dig(:interval)
        name = derive_name(
          source_table: mapped[:source_table],
          bucket_interval: name_interval,
          filters: filters,
          value_column: value_column
        )
        validate_name!(name)

        bucket_interval = name_interval.presence || "1 minute"
        bucket_column = time_bucket&.dig(:column).presence || "timestamp"

        {
          name: name,
          metric_type: "gauge",
          source_table: mapped[:source_table],
          bucket_interval: bucket_interval,
          bucket_column: bucket_column,
          time_bucketed: time_bucket.present?,
          dimensions: dimensions,
          value_column: value_column,
          scale: scale,
          filters: filters,
          unsupported_predicates: mapped[:unsupported_predicates],
          time_range: mapped[:time_range],
          columns: build_columns(dimension_columns),
          primary_key: dimension_columns
        }
      end

      # Parse value_column from a gauge metric name (..._avg_<col>_gauge).
      def self.value_column_from_name(name)
        match = name.to_s.match(/_avg_([a-z0-9_]+)_gauge\z/)
        match && match[1]
      end

      private

      def validate!(mapped)
        raise UnsupportedError, "source table is required" if mapped[:source_table].blank?
        raise UnsupportedError, "only gauge metrics are supported" unless mapped[:metric_type] == "gauge"
        raise UnsupportedError, "unsupported where predicates" if mapped[:unsupported_predicates]

        avgs = Array(mapped[:res_targets]).select { |t| t[:kind] == :agg && t[:func] == "avg" }
        raise UnsupportedError, "exactly one AVG aggregate is required" unless avgs.size == 1
        raise UnsupportedError, "AVG column is required" if avgs.first[:column].blank?
      end

      def avg_target(res_targets)
        Array(res_targets).find { |t| t[:kind] == :agg && t[:func] == "avg" }
      end

      def derive_name(source_table:, bucket_interval:, filters:, value_column:)
        parts = [ source_table ]
        parts << TraceToMetric.slugify_span_name(bucket_interval) if bucket_interval.present?
        parts.concat(filters.map { |f| filter_slug(f) })
        parts << "avg_#{TraceToMetric.sanitize_dimension(value_column)}"
        parts << "gauge"
        TraceToMetric.slugify_span_name(parts.join("_"))
      end

      def filter_slug(filter)
        column = TraceToMetric.sanitize_dimension(filter[:column])
        value_slug = TraceToMetric.sanitize_dimension(filter[:value])
        case filter[:op]
        when "IS NULL"
          "#{column}_is_null"
        when "IS NOT NULL"
          "#{column}_is_not_null"
        when "="
          "#{column}_#{value_slug}"
        when "<"
          "#{column}_lt_#{value_slug}"
        when "<="
          "#{column}_lte_#{value_slug}"
        when ">"
          "#{column}_gt_#{value_slug}"
        when ">="
          "#{column}_gte_#{value_slug}"
        when SqlToMetrics::Mapper::NULL_OR_NOT_EQUAL_OP
          "#{column}_is_null_or_ne_#{value_slug}"
        else
          column
        end
      end

      def build_columns(dimension_columns)
        [
          { name: "bucket", type: "TIMESTAMP", time_index: true },
          *dimension_columns.map { |name| { name: name, type: "STRING" } },
          { name: "value_sum", type: "DOUBLE" },
          { name: "value_count", type: "BIGINT" }
        ]
      end

      def validate_name!(name)
        unless name.match?(TraceToMetric::NAME_FORMAT)
          raise UnsupportedError, "derived metric name is invalid: #{name}"
        end
        if TraceToMetric::RESERVED_TABLE_NAMES.include?(name)
          raise UnsupportedError, "derived metric name is reserved: #{name}"
        end
      end
    end
  end
end
