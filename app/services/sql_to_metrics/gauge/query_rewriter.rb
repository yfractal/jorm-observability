# frozen_string_literal: true

module SqlToMetrics
  module Gauge
    # Rewrites AVG analytics queries to metric (value_sum/value_count) + raw UNION.
    # Reuses Coverage and Interval from the counter path; only SQL construction differs.
    class QueryRewriter
      Result = Struct.new(:sql, :used_metric, :segments, :metric_name, keyword_init: true)

      def self.call(sql)
        new(sql).call
      end

      def initialize(sql)
        @sql = sql.to_s
      end

      def call
        mapped = Mapper.call(@sql)
        spec = TableSpec.call(@sql)

        unless compatible?(mapped, spec)
          return Result.new(sql: @sql, used_metric: false, segments: { metric: nil, raw: [ :all ] }, metric_name: nil)
        end

        coverage = Coverage.call(spec[:name], bucket_interval: spec[:bucket_interval])
        unless coverage
          return Result.new(sql: @sql, used_metric: false, segments: { metric: nil, raw: [ :all ] }, metric_name: spec[:name])
        end

        query_range = resolve_query_range(mapped[:time_range])
        # Split on the stored 1-minute grid so $per queries still use complete
        # metric minutes, then re-bin in the outer SELECT.
        segments = SqlToMetrics::QueryRewriter.split_ranges(query_range, coverage, spec[:bucket_interval])

        if segments[:metric].nil?
          return Result.new(sql: @sql, used_metric: false, segments: segments, metric_name: spec[:name])
        end

        rewritten = build_sql(mapped, spec, segments)
        Result.new(sql: rewritten, used_metric: true, segments: segments, metric_name: spec[:name])
      end

      private

      def compatible?(mapped, spec)
        return false if spec[:bucket_interval].blank?
        return false if spec[:query_interval].blank?
        return false unless Interval.multiple?(spec[:query_interval], spec[:bucket_interval])
        return false if spec[:bucket_column].blank?
        return false if spec[:value_column].blank?
        return false unless Greptime::Connection.table_exists?(spec[:name])

        metric_cols = Greptime::Connection.column_names(spec[:name])
        return false unless metric_cols.include?("bucket") &&
          metric_cols.include?("value_sum") &&
          metric_cols.include?("value_count")

        query_dims = Array(spec[:dimensions]).map { |d| TraceToMetric.sanitize_dimension(d) }
        metric_dims = metric_cols - %w[bucket value_sum value_count]
        return false unless query_dims.all? { |d| metric_dims.include?(d) }

        true
      end

      def resolve_query_range(time_range)
        {
          from: resolve_bound(time_range&.dig(:from)),
          to: resolve_bound(time_range&.dig(:to))
        }
      end

      def resolve_bound(bound)
        return nil if bound.nil?

        value = bound[:value]
        time =
          case value[:kind]
          when :literal
            parse_utc_timestamp(value[:value])
          when :now
            Time.now.utc
          when :now_minus
            Time.now.utc - Interval.seconds(value[:interval])
          when :now_plus
            Time.now.utc + Interval.seconds(value[:interval])
          else
            raise UnsupportedError, "unsupported time bound kind: #{value[:kind].inspect}"
          end

        { time: time, inclusive: bound[:inclusive] }
      end

      def build_sql(mapped, spec, segments)
        connection = Greptime::Connection
        storage_interval = spec[:bucket_interval]
        query_interval = spec[:query_interval]
        bucket_column = spec[:bucket_column]
        dimensions = Array(spec[:dimensions])
        dim_cols = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
        quoted_dims = dim_cols.map { |c| connection.quote_column_name(c) }
        avg_alias = avg_alias_for(mapped)
        scale = spec[:scale]

        metric_sql = build_metric_subquery(spec, dim_cols, quoted_dims, segments[:metric])
        raw_sql = build_raw_subquery(mapped, spec, dimensions, quoted_dims, bucket_column, storage_interval, segments[:raw])

        inner =
          if raw_sql
            "#{metric_sql}\n  UNION ALL\n  #{raw_sql}"
          else
            metric_sql
          end

        mean_expr = mean_select_expr(avg_alias, scale)

        unless spec[:time_bucketed]
          return <<~SQL.squish
            SELECT #{mean_expr}
            FROM (
              #{inner}
            ) AS metric_query
          SQL
        end

        time_alias = mapped[:time_bucket]&.dig(:alias).presence || "time"
        outer_select = [
          "date_bin(#{connection.quote(query_interval)}, bucket) AS #{connection.quote_column_name(time_alias)}",
          *quoted_dims,
          mean_expr
        ].join(", ")

        group_list = [ connection.quote_column_name(time_alias), *quoted_dims ].join(", ")

        <<~SQL.squish
          SELECT #{outer_select}
          FROM (
            #{inner}
          ) AS metric_query
          GROUP BY #{group_list}
          ORDER BY #{connection.quote_column_name(time_alias)}
        SQL
      end

      def mean_select_expr(avg_alias, scale)
        connection = Greptime::Connection
        mean = "SUM(value_sum) / NULLIF(SUM(value_count), 0)"
        scaled =
          if scale.nil?
            mean
          else
            "(#{mean}) / #{scale}"
          end
        "#{scaled} AS #{connection.quote_column_name(avg_alias)}"
      end

      def build_metric_subquery(spec, dim_cols, quoted_dims, metric_segment)
        connection = Greptime::Connection
        table = connection.quote_table_name(spec[:name])
        select_list = [
          "bucket",
          *quoted_dims,
          "SUM(value_sum) AS value_sum",
          "SUM(value_count) AS value_count"
        ].join(", ")
        group_list = [ "bucket", *quoted_dims ].join(", ")
        where = time_predicate("bucket", metric_segment)

        <<~SQL.squish
          SELECT #{select_list}
          FROM #{table}
          WHERE #{where}
          GROUP BY #{group_list}
        SQL
      end

      def build_raw_subquery(mapped, spec, dimensions, quoted_dims, bucket_column, interval, raw_segments)
        return nil if raw_segments.nil? || raw_segments.empty?
        return nil if raw_segments == [ :all ]

        connection = Greptime::Connection
        source = connection.quote_table_name(spec[:source_table])
        quoted_bucket_col = connection.quote_column_name(bucket_column)
        quoted_source_dims = dimensions.map { |d| connection.quote_column_name(d) }
        quoted_value = connection.quote_column_name(spec[:value_column])

        select_list = [
          "date_bin(#{connection.quote(interval)}, #{quoted_bucket_col}) AS bucket",
          *quoted_source_dims,
          "SUM(#{quoted_value}) AS value_sum",
          "COUNT(#{quoted_value}) AS value_count"
        ].join(", ")

        group_list = [ "bucket", *quoted_source_dims ].join(", ")

        filter_sql = non_time_filter_sql(mapped[:filters])
        time_sql = raw_time_predicate(quoted_bucket_col, raw_segments)
        where_parts = [ filter_sql, time_sql ].compact.reject(&:blank?)
        where = where_parts.empty? ? "TRUE" : where_parts.join(" AND ")

        <<~SQL.squish
          SELECT #{select_list}
          FROM #{source}
          WHERE #{where}
          GROUP BY #{group_list}
        SQL
      end

      def non_time_filter_sql(filters)
        parts = Array(filters).filter_map do |filter|
          col = Greptime::Connection.quote_column_name(filter[:column])
          case filter[:op]
          when "IS NULL"
            "#{col} IS NULL"
          when "IS NOT NULL"
            "#{col} IS NOT NULL"
          when "=", "<", "<=", ">", ">="
            "#{col} #{filter[:op]} #{quote_filter_value(filter[:value])}"
          when Mapper::NULL_OR_NOT_EQUAL_OP, SqlToMetrics::Mapper::NULL_OR_NOT_EQUAL_OP
            "(#{col} IS NULL OR #{col} != #{quote_filter_value(filter[:value])})"
          end
        end
        return nil if parts.empty?

        parts.join(" AND ")
      end

      def quote_filter_value(value)
        case value
        when Integer, Float then value.to_s
        when TrueClass then "TRUE"
        when FalseClass then "FALSE"
        else Greptime::Connection.quote(value.to_s)
        end
      end

      def raw_time_predicate(quoted_column, segments)
        parts = segments.map { |seg| "(#{time_predicate(quoted_column, seg)})" }
        return nil if parts.empty?

        parts.size == 1 ? parts.first : "(#{parts.join(' OR ')})"
      end

      def time_predicate(column, segment)
        quoted =
          if column.start_with?('"') || column.include?("(")
            column
          else
            Greptime::Connection.quote_column_name(column)
          end

        parts = []
        parts << "#{quoted} >= #{quote_time(segment[:from])}" unless segment[:from].nil?
        parts << "#{quoted} < #{quote_time(segment[:to])}" unless segment[:to].nil?
        parts.empty? ? "TRUE" : parts.join(" AND ")
      end

      def quote_time(time)
        Greptime::Connection.quote(time.utc.strftime("%Y-%m-%d %H:%M:%S.%6N"))
      end

      def avg_alias_for(mapped)
        agg = Array(mapped[:res_targets]).find { |t| t[:kind] == :agg && t[:func] == "avg" }
        agg&.dig(:alias).presence || "value"
      end

      def parse_utc_timestamp(value)
        text = value.to_s.strip
        if text.match?(/[zZ]|[+-]\d{2}(:?\d{2})?\z/)
          return Time.parse(text).utc
        end

        Time.find_zone!("UTC").parse(text).utc
      end
    end
  end
end
