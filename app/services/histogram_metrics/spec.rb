module HistogramMetrics
  # Derives a histogram metric definition from a dashboard query such as
  #
  #   SELECT date_bin('1 minute', timestamp) AS time,
  #          approx_percentile_cont(duration_nano, 0.99) / 1e6 AS p99
  #   FROM opentelemetry_traces WHERE ... GROUP BY time ORDER BY time
  #
  # Quantiles and $per are not part of the metric: p99/p95/p50 and every Grafana
  # $per of one panel share a 1-minute sketch table. Filters, time range, and
  # dimensions come from SqlToMetrics::Mapper.
  class Spec
    PERCENTILE_ALIAS = "approx_percentile_cont".freeze
    STORAGE_INTERVAL = "1 minute"

    def self.call(sql)
      new(sql).call
    end

    def initialize(sql)
      @sql = sql.to_s
    end

    def call
      mapped = SqlToMetrics::Mapper.call(@sql)
      raise SqlToMetrics::UnsupportedError, "source table is required" if mapped[:source_table].blank?
      raise SqlToMetrics::UnsupportedError, "unsupported where predicates" if mapped[:unsupported_predicates]

      select = PgQuery.parse(@sql).tree.stmts.first.stmt.select_stmt
      outputs = build_outputs(select, mapped)
      value_columns = outputs.filter_map { |o| o[:value_column] }.uniq
      raise SqlToMetrics::UnsupportedError, "exactly one histogram value column is required" unless value_columns.size == 1

      time_bucket = mapped[:time_bucket]
      value_column = value_columns.first
      filters = Array(mapped[:filters])
      query_interval = time_bucket&.dig(:interval).presence || STORAGE_INTERVAL

      {
        name: derive_name(mapped[:source_table], filters, value_column),
        metric_type: "histogram",
        source_table: mapped[:source_table],
        bucket_interval: STORAGE_INTERVAL,
        query_interval: query_interval,
        bucket_column: time_bucket&.dig(:column).presence || "timestamp",
        time_bucketed: time_bucket.present?,
        time_alias: time_bucket&.dig(:alias).presence || "time",
        dimensions: Array(mapped[:dimensions]),
        value_column: value_column,
        filters: filters,
        time_range: mapped[:time_range],
        outputs: outputs
      }
    end

    private

    # One entry per SELECT item, in order:
    #   { kind: :time }
    #   { kind: :dimension, column: "scope_name", alias: ... }
    #   { kind: :percentile, value_column:, sql: "<expr over the merged sketch>", alias: }
    def build_outputs(select, mapped)
      time_alias = mapped[:time_bucket]&.dig(:alias)

      select.target_list.map do |node|
        target = node.res_target
        val = target.val
        alias_name = target.name.presence

        if (holder = find_percentile_holder(val))
          column, quantile = percentile_args(holder.func_call)
          holder.func_call = replacement_func(quantile)
          { kind: :percentile, value_column: column, alias: alias_name || PERCENTILE_ALIAS, sql: deparse(val) }
        elsif val.func_call && SqlToMetrics::Mapper::TIME_BUCKET_FUNCS.include?(func_name(val.func_call))
          { kind: :time, alias: alias_name || time_alias || "time" }
        elsif val.column_ref
          { kind: :dimension, column: column_name(val), alias: alias_name }
        else
          raise SqlToMetrics::UnsupportedError, "unsupported select item for histogram metric"
        end
      end
    end

    # Finds the Node whose func_call is approx_percentile_cont, looking through
    # arithmetic (`/ 1e6`) and casts.
    def find_percentile_holder(node)
      return nil if node.nil?

      if (func = node.func_call)
        return node if func_name(func) == PERCENTILE_FUNC

        return func.args.lazy.map { |arg| find_percentile_holder(arg) }.find(&:itself)
      end
      if (expr = node.a_expr)
        return find_percentile_holder(expr.lexpr) || find_percentile_holder(expr.rexpr)
      end
      return find_percentile_holder(node.type_cast.arg) if node.type_cast

      nil
    end

    def percentile_args(func)
      column_node, quantile_node = func.args.to_a
      column = column_name(column_node)
      raise SqlToMetrics::UnsupportedError, "#{PERCENTILE_FUNC} needs a column as first argument" if column.nil?

      quantile = const_number(quantile_node)
      unless quantile && quantile.positive? && quantile < 1
        raise SqlToMetrics::UnsupportedError, "#{PERCENTILE_FUNC} needs a constant quantile in (0, 1)"
      end

      [ column, quantile ]
    end

    # uddsketch_calc(q, uddsketch_merge(..., sketch)) over the sketch column of the combined subquery.
    def replacement_func(quantile)
      sql = HistogramMetrics.sketch_calc_sql(
        quantile,
        HistogramMetrics.sketch_merge_sql(Greptime::Connection.quote_column_name(SKETCH_COLUMN))
      )
      PgQuery.parse("SELECT #{sql}").tree.stmts.first.stmt.select_stmt.target_list.first.res_target.val.func_call
    end

    def derive_name(source_table, filters, value_column)
      table_spec = SqlToMetrics::TableSpec.new(@sql)
      parts = [ source_table ]
      parts.concat(filters.map { |f| table_spec.slug_for_filter(f) })
      parts << TraceToMetric.sanitize_dimension(value_column)
      parts << "histogram"
      name = TraceToMetric.slugify_span_name(parts.join("_"))
      unless name.match?(TraceToMetric::NAME_FORMAT) && !TraceToMetric::RESERVED_TABLE_NAMES.include?(name)
        raise SqlToMetrics::UnsupportedError, "derived metric name is invalid: #{name}"
      end

      name
    end

    def func_name(func)
      func.funcname.map { |n| n.string&.sval }.compact.join(".").downcase
    end

    def column_name(node)
      node&.column_ref&.fields&.filter_map { |f| f.string&.sval }&.last
    end

    def const_number(node)
      c = node&.a_const
      return nil unless c

      return c.fval.fval.to_f if c.fval
      return c.ival.ival.to_f if c.ival

      nil
    end

    # Wrap a single expression as SELECT <expr> so pg_query can deparse it.
    def deparse(node)
      select = PgQuery::SelectStmt.new(
        target_list: [
          PgQuery::Node.new(res_target: PgQuery::ResTarget.new(name: "", indirection: [], val: node, location: -1))
        ],
        from_clause: [], group_clause: [], distinct_clause: [], window_clause: [],
        values_lists: [], sort_clause: [], locking_clause: [], op: :SETOP_NONE
      )
      tree = PgQuery::ParseResult.new(
        version: PgQuery::PG_VERSION_NUM,
        stmts: [ PgQuery::RawStmt.new(stmt: PgQuery::Node.new(select_stmt: select)) ]
      )
      PgQuery::ParserResult.new("", tree, []).deparse.sub(/\ASELECT\s+/i, "")
    end
  end
end
