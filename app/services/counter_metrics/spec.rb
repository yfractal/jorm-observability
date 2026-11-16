module CounterMetrics
  class Spec
    def self.call(sql)
      new(sql).call
    end

    def initialize(sql)
      @sql = sql
    end

    def call
      mapped = SqlToMetrics::Mapper.call(@sql)
      validate!(mapped)

      dimensions = Array(mapped[:dimensions])
      dimension_columns = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
      distinct_column = extract_distinct_column(mapped[:res_targets])
      time_bucket = mapped[:time_bucket]
      filters = Array(mapped[:filters])
      # Name keeps the query's date_bin interval only — bare COUNT names omit it.
      name_interval = time_bucket&.dig(:interval)
      name = derive_name(
        source_table: mapped[:source_table],
        bucket_interval: name_interval,
        filters: filters,
        distinct_column: distinct_column
      )
      validate_name!(name)

      # Bare COUNT still materializes into minute buckets (BackfillJob default).
      bucket_interval = name_interval.presence || "1 minute"
      bucket_column = time_bucket&.dig(:column).presence || "timestamp"

      {
        name: name,
        metric_type: "counter",
        source_table: mapped[:source_table],
        bucket_interval: bucket_interval,
        bucket_column: bucket_column,
        time_bucketed: time_bucket.present?,
        dimensions: dimensions,
        distinct_column: distinct_column,
        filters: filters,
        unsupported_predicates: mapped[:unsupported_predicates],
        time_range: mapped[:time_range],
        columns: build_columns(dimension_columns),
        primary_key: dimension_columns
      }
    end

    # Shared with HistogramMetrics::Spec so filter slugs in metric names stay identical.
    def slug_for_filter(filter)
      filter_slug(filter)
    end

    private

    def validate!(mapped)
      raise SqlToMetrics::UnsupportedError, "source table is required" if mapped[:source_table].blank?
      raise SqlToMetrics::UnsupportedError, "only counter metrics are supported" unless mapped[:metric_type] == "counter"
      raise SqlToMetrics::UnsupportedError, "unsupported where predicates" if mapped[:unsupported_predicates]

      counter_aggs = Array(mapped[:res_targets]).select { |t| t[:kind] == :agg && t[:func] == "count" }
      raise SqlToMetrics::UnsupportedError, "exactly one counter aggregate is required" unless counter_aggs.size == 1
    end

    def extract_distinct_column(res_targets)
      agg = Array(res_targets).find { |t| t[:kind] == :agg && t[:func] == "count" }
      return nil unless agg&.dig(:distinct)

      args = Array(agg[:args])
      return nil if args.empty? || args == [ "*" ]

      args.first
    end

    def derive_name(source_table:, bucket_interval:, filters:, distinct_column:)
      parts = [ source_table ]
      parts << TraceToMetric.slugify_span_name(bucket_interval) if bucket_interval.present?
      parts.concat(filters.map { |f| filter_slug(f) })
      parts << "distinct_#{TraceToMetric.sanitize_dimension(distinct_column)}" if distinct_column.present?
      parts << "counter"
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
        { name: "value", type: "BIGINT" }
      ]
    end

    def validate_name!(name)
      unless name.match?(TraceToMetric::NAME_FORMAT)
        raise SqlToMetrics::UnsupportedError, "derived metric name is invalid: #{name}"
      end
      if TraceToMetric::RESERVED_TABLE_NAMES.include?(name)
        raise SqlToMetrics::UnsupportedError, "derived metric name is reserved: #{name}"
      end
    end
  end
end
