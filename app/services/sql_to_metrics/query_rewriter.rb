module SqlToMetrics
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

      coverage = Coverage.call(spec[:name], bucket_interval: metric_interval(spec))
      unless coverage
        return Result.new(sql: @sql, used_metric: false, segments: { metric: nil, raw: [ :all ] }, metric_name: spec[:name])
      end

      query_range = resolve_query_range(mapped[:time_range])
      segments = split_ranges(query_range, coverage, spec[:bucket_interval])

      if segments[:metric].nil?
        return Result.new(sql: @sql, used_metric: false, segments: segments, metric_name: spec[:name])
      end

      rewritten = build_sql(mapped, spec, segments)
      Result.new(sql: rewritten, used_metric: true, segments: segments, metric_name: spec[:name])
    end

    # Pure range split used by specs and call.
    def self.split_ranges(query_range, coverage, bucket_interval)
      new("").send(:split_ranges, query_range, coverage, bucket_interval)
    end

    private

    def compatible?(mapped, spec)
      return false if spec[:bucket_interval].blank?
      return false if spec[:bucket_column].blank?
      return false unless Greptime::Connection.table_exists?(spec[:name])

      metric_cols = Greptime::Connection.column_names(spec[:name])
      return false unless metric_cols.include?("bucket") && metric_cols.include?("value")

      query_dims = Array(spec[:dimensions]).map { |d| TraceToMetric.sanitize_dimension(d) }
      metric_dims = metric_cols - %w[bucket value]
      return false unless query_dims.all? { |d| metric_dims.include?(d) }

      if spec[:distinct_column].present?
        # Only use a metric built for the same distinct column (encoded in the name).
        return false unless spec[:name].include?("distinct_#{TraceToMetric.sanitize_dimension(spec[:distinct_column])}")
      end

      # Interval must match the metric's baked-in interval (from the name), or be a multiple.
      # Metric tables are named with their interval; we require the query interval to be a
      # multiple of itself for now when the table exists under that derived name — identical.
      true
    end

    def metric_interval(spec)
      spec[:bucket_interval]
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

    def normalize_half_open(query_range)
      from_bound = query_range[:from]
      to_bound = query_range[:to]

      from =
        if from_bound.nil?
          nil
        elsif from_bound[:inclusive]
          from_bound[:time]
        else
          from_bound[:time] + Rational(1, 1_000_000)
        end

      to =
        if to_bound.nil?
          nil
        elsif to_bound[:inclusive]
          to_bound[:time] + Rational(1, 1_000_000)
        else
          to_bound[:time]
        end

      { from: from, to: to }
    end

    def split_ranges(query_range, coverage, bucket_interval)
      q = normalize_half_open(query_range)
      qs = q[:from]
      qe = q[:to]
      cs = coverage[:from]
      ce = coverage[:to]

      metric_from =
        if qs.nil?
          cs
        else
          [ Interval.ceil_bucket(qs, bucket_interval), cs ].max
        end

      metric_to =
        if qe.nil?
          ce
        else
          [ Interval.floor_bucket(qe, bucket_interval), ce ].min
        end

      if metric_from < metric_to
        {
          metric: { from: metric_from, to: metric_to },
          raw: compact_segments([
            (qs.nil? && metric_from == cs) ? nil : { from: qs, to: metric_from },
            (qe.nil? && metric_to == ce) ? nil : { from: metric_to, to: qe }
          ])
        }
      else
        {
          metric: nil,
          raw: [ { from: qs, to: qe } ]
        }
      end
    end

    def compact_segments(segments)
      segments.compact.reject do |seg|
        from = seg[:from]
        to = seg[:to]
        !from.nil? && !to.nil? && from >= to
      end
    end

    def build_sql(mapped, spec, segments)
      connection = Greptime::Connection
      interval = spec[:bucket_interval]
      bucket_column = spec[:bucket_column]
      dimensions = Array(spec[:dimensions])
      dim_cols = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
      quoted_dims = dim_cols.map { |c| connection.quote_column_name(c) }
      count_alias = count_alias_for(mapped)

      metric_sql = build_metric_subquery(spec, dim_cols, quoted_dims, segments[:metric])
      raw_sql = build_raw_subquery(mapped, spec, dimensions, quoted_dims, bucket_column, interval, segments[:raw])

      inner =
        if raw_sql
          "#{metric_sql}\n  UNION ALL\n  #{raw_sql}"
        else
          metric_sql
        end

      # Bare COUNT(*) queries have no date_bin — collapse buckets to a single SUM.
      unless spec[:time_bucketed]
        return <<~SQL.squish
          SELECT SUM(value) AS #{connection.quote_column_name(count_alias)}
          FROM (
            #{inner}
          ) AS metric_query
        SQL
      end

      time_alias = mapped[:time_bucket]&.dig(:alias).presence || "time"
      outer_select = [
        "date_bin(#{connection.quote(interval)}, bucket) AS #{connection.quote_column_name(time_alias)}",
        *quoted_dims,
        "SUM(value) AS #{connection.quote_column_name(count_alias)}"
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

    def build_metric_subquery(spec, dim_cols, quoted_dims, metric_segment)
      connection = Greptime::Connection
      table = connection.quote_table_name(spec[:name])
      select_list = [ "bucket", *quoted_dims, "SUM(value) AS value" ].join(", ")
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

      select_list = [
        "date_bin(#{connection.quote(interval)}, #{quoted_bucket_col}) AS bucket",
        *quoted_source_dims,
        raw_count_expr(mapped)
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

    def raw_count_expr(mapped)
      agg = Array(mapped[:res_targets]).find { |t| t[:kind] == :agg && t[:func] == "count" }
      if agg&.dig(:distinct)
        args = Array(agg[:args])
        col = args.first
        "COUNT(DISTINCT #{Greptime::Connection.quote_column_name(col)}) AS value"
      else
        "COUNT(*) AS value"
      end
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
        when Mapper::NULL_OR_NOT_EQUAL_OP
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
      # column may already be quoted or be a bare name like "bucket"
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

    def count_alias_for(mapped)
      agg = Array(mapped[:res_targets]).find { |t| t[:kind] == :agg && t[:func] == "count" }
      agg&.dig(:alias).presence || "count"
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
