module HistogramMetrics
  # Same metric/raw range split as the counter rewriter. Both segments produce
  # (bucket, dimensions, sketch); the outer query merges the sketches, re-bins to
  # the query interval and evaluates each quantile with uddsketch_calc.
  class QueryRewriter < CounterMetrics::QueryRewriter
    def self.call(sql)
      new(sql).call
    end

    def call
      spec = Spec.call(@sql)
      mapped = SqlToMetrics::Mapper.call(@sql)

      return passthrough(nil, spec[:name]) unless compatible?(spec)

      coverage = SqlToMetrics::Coverage.call(spec[:name], bucket_interval: spec[:bucket_interval])
      return passthrough(nil, spec[:name]) unless coverage

      # Split on the stored 1-minute grid so $per queries still use complete
      # metric minutes, then re-bin in the outer SELECT.
      segments = split_ranges(resolve_query_range(mapped[:time_range]), coverage, spec[:bucket_interval])
      return passthrough(segments, spec[:name]) if segments[:metric].nil?

      Result.new(sql: build_histogram_sql(spec, segments), used_metric: true, segments: segments, metric_name: spec[:name])
    end

    private

    def passthrough(segments, metric_name)
      Result.new(sql: @sql, used_metric: false, segments: segments || { metric: nil, raw: [ :all ] }, metric_name: metric_name)
    end

    def compatible?(spec)
      connection = Greptime::Connection
      return false if spec[:bucket_interval].blank? || spec[:query_interval].blank?
      return false unless SqlToMetrics::Interval.multiple?(spec[:query_interval], spec[:bucket_interval])
      return false unless connection.table_exists?(spec[:name])

      columns = connection.column_names(spec[:name])
      return false unless columns.include?("bucket") && columns.include?(SKETCH_COLUMN)

      spec[:dimensions].all? { |d| columns.include?(TraceToMetric.sanitize_dimension(d)) }
    end

    def build_histogram_sql(spec, segments)
      connection = Greptime::Connection
      dim_cols = spec[:dimensions].map { |d| TraceToMetric.sanitize_dimension(d) }
      quoted_dims = dim_cols.map { |c| connection.quote_column_name(c) }
      sketch = connection.quote_column_name(SKETCH_COLUMN)

      metric_sql = <<~SQL.squish
        SELECT bucket, #{[ *quoted_dims, sketch ].join(', ')}
        FROM #{connection.quote_table_name(spec[:name])}
        WHERE #{time_predicate('bucket', segments[:metric])}
      SQL
      raw_sql = build_raw_sketch_subquery(spec, segments[:raw])
      inner = raw_sql ? "#{metric_sql} UNION ALL #{raw_sql}" : metric_sql

      time_alias = connection.quote_column_name(spec[:time_alias])
      select_list = spec[:outputs].map do |output|
        case output[:kind]
        when :time
          "date_bin(#{connection.quote(spec[:query_interval])}, bucket) AS #{connection.quote_column_name(output[:alias])}"
        when :dimension
          column = connection.quote_column_name(TraceToMetric.sanitize_dimension(output[:column]))
          output[:alias] ? "#{column} AS #{connection.quote_column_name(output[:alias])}" : column
        when :percentile
          "#{output[:sql]} AS #{connection.quote_column_name(output[:alias])}"
        end
      end
      group_list = [ (time_alias if spec[:time_bucketed]), *quoted_dims ].compact
      group_sql = group_list.empty? ? "" : " GROUP BY #{group_list.join(', ')}"
      order_sql = spec[:time_bucketed] ? " ORDER BY #{time_alias}" : ""

      "SELECT #{select_list.join(', ')} FROM (#{inner}) AS metric_query#{group_sql}#{order_sql}"
    end

    def build_raw_sketch_subquery(spec, raw_segments)
      return nil if raw_segments.blank? || raw_segments == [ :all ]

      connection = Greptime::Connection
      bucket_column = connection.quote_column_name(spec[:bucket_column])
      value_column = connection.quote_column_name(spec[:value_column])
      source_dims = spec[:dimensions].map { |d| connection.quote_column_name(d) }
      dim_selects = spec[:dimensions].map { |d| "#{connection.quote_column_name(d)} AS #{connection.quote_column_name(TraceToMetric.sanitize_dimension(d))}" }

      where = [
        non_time_filter_sql(spec[:filters]),
        raw_time_predicate(bucket_column, raw_segments),
        "#{value_column} IS NOT NULL"
      ].compact_blank.join(" AND ")

      <<~SQL.squish
        SELECT date_bin(#{connection.quote(spec[:bucket_interval])}, #{bucket_column}) AS bucket,
               #{[ *dim_selects, "#{HistogramMetrics.sketch_state_sql(value_column)} AS #{connection.quote_column_name(SKETCH_COLUMN)}" ].join(', ')}
        FROM #{connection.quote_table_name(spec[:source_table])}
        WHERE #{where}
        GROUP BY #{[ 'bucket', *source_dims ].join(', ')}
      SQL
    end
  end
end
