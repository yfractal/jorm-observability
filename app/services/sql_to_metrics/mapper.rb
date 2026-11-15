require "pg_query"

module SqlToMetrics
  class Mapper
    COUNTER_FUNCS = %w[count].freeze
    TIME_BUCKET_FUNCS = %w[date_bin].freeze

    def self.call(sql)
      new(sql).call
    end

    def initialize(sql)
      @sql = sql.to_s
    end

    RANGE_OPS = %w[>= > <= <].freeze
    FILTER_COMPARE_OPS = (%w[=] + RANGE_OPS).freeze

    def call
      select = select_stmt!
      res_targets = select.target_list.map { |node| classify_res_target(node.res_target) }
      time_bucket = extract_time_bucket(res_targets)
      time_column = time_bucket&.dig(:column)
      filters, time_range = extract_filters_and_time_range(select.where_clause, time_column)
      {
        metric_type: metric_type_for(res_targets),
        dimensions: extract_dimensions(select, time_bucket),
        time_bucket: time_bucket,
        time_range: time_range,
        res_targets: res_targets,
        filters: filters,
        unsupported_predicates: unsupported_predicates?(select.where_clause, time_column),
        source_table: extract_source_table(select)
      }
    end

    private

    def select_stmt!
      tree = PgQuery.parse(@sql).tree
      stmt = tree.stmts.first&.stmt&.select_stmt
      raise ParseError, "expected a SELECT statement" unless stmt

      stmt
    rescue PgQuery::ParseError => e
      raise ParseError, e.message
    end

    def classify_res_target(res_target)
      alias_name = res_target.name.presence
      func = res_target.val&.func_call

      if func && time_bucket_func?(func)
        interval, column = time_bucket_args(func)
        {
          alias: alias_name,
          kind: :time_bucket,
          interval: interval,
          column: column
        }
      elsif func && counter_func?(func)
        {
          alias: alias_name,
          kind: :agg,
          func: func_name(func),
          distinct: func.agg_distinct,
          args: func_args(func)
        }
      else
        {
          alias: alias_name || column_name_from_node(res_target.val),
          kind: :other,
          expr: deparse_expr(res_target.val)
        }
      end
    end

    def extract_time_bucket(res_targets)
      target = res_targets.find { |t| t[:kind] == :time_bucket }
      return nil unless target

      {
        interval: target[:interval],
        column: target[:column],
        alias: target[:alias]
      }
    end

    def extract_source_table(select)
      from = select.from_clause.first
      return nil unless from&.range_var

      from.range_var.relname.presence
    end

    def extract_dimensions(select, time_bucket)
      time_aliases = [
        time_bucket&.dig(:alias),
        time_bucket && "date_bin"
      ].compact

      select.group_clause.filter_map do |node|
        name = group_item_name(node)
        next if name.nil?
        next if time_aliases.include?(name)
        next if time_bucket && matches_time_bucket_expr?(node, time_bucket)

        name
      end
    end

    def extract_filters(where_node)
      extract_filters_and_time_range(where_node, nil).first
    end

    def extract_filters_and_time_range(where_node, time_column)
      empty_range = { from: nil, to: nil }
      return [ [], empty_range ] if where_node.nil?

      time_range = { from: nil, to: nil }
      filters = []
      bound_column = time_column.presence || "timestamp"

      flatten_bool_and(where_node).each do |node|
        next if skippable_predicate?(node)

        if (bound = classify_time_bound(node, bound_column))
          merge_time_bound!(time_range, bound)
        elsif (filter = classify_filter(node))
          filters << filter
        end
      end

      [ filters, time_range ]
    end

    def unsupported_predicates?(where_node, time_column)
      return false if where_node.nil?

      # Bare COUNT queries have no date_bin, but still filter on timestamp.
      bound_column = time_column.presence || "timestamp"

      flatten_bool_and(where_node).any? do |node|
        next false if skippable_predicate?(node)
        begin
          next false if classify_time_bound(node, bound_column)
        rescue UnsupportedError
          next true
        end
        next false if classify_filter(node)

        true
      end
    end

    # Grafana "All services" expands to ('__all__' = '__all__' OR service_name = '__all__').
    def skippable_predicate?(node)
      return false unless node.bool_expr && node.bool_expr.boolop == :OR_EXPR

      Array(node.bool_expr.args).any? { |arg| constant_true_equality?(arg) }
    end

    def constant_true_equality?(node)
      return false unless node.a_expr

      expr = node.a_expr
      op = expr.name.map { |n| n.string&.sval }.compact.join
      return false unless op == "="

      left = const_string(expr.lexpr) || (const_value(expr.lexpr).is_a?(String) ? const_value(expr.lexpr) : nil)
      right = const_string(expr.rexpr) || (const_value(expr.rexpr).is_a?(String) ? const_value(expr.rexpr) : nil)
      !left.nil? && left == right
    end

    def metric_type_for(res_targets)
      return "counter" if res_targets.any? { |t| t[:kind] == :agg && COUNTER_FUNCS.include?(t[:func]) }

      nil
    end

    def time_bucket_func?(func)
      TIME_BUCKET_FUNCS.include?(func_name(func))
    end

    def counter_func?(func)
      COUNTER_FUNCS.include?(func_name(func))
    end

    def func_name(func)
      func.funcname.map { |n| n.string&.sval }.compact.join(".").downcase
    end

    def func_args(func)
      return [ "*" ] if func.agg_star

      func.args.map { |arg| column_name_from_node(arg) || deparse_expr(arg) }
    end

    def time_bucket_args(func)
      interval_node, column_node = func.args
      interval = const_string(interval_node) || deparse_expr(interval_node)
      column = column_name_from_node(column_node) || deparse_expr(column_node)
      [ interval, column ]
    end

    def group_item_name(node)
      return column_name_from_node(node) if node.column_ref

      if node.func_call && time_bucket_func?(node.func_call)
        return "date_bin"
      end

      deparse_expr(node)
    end

    def matches_time_bucket_expr?(node, time_bucket)
      return false unless node.func_call && time_bucket_func?(node.func_call)

      interval, column = time_bucket_args(node.func_call)
      interval == time_bucket[:interval] && column == time_bucket[:column]
    end

    def flatten_bool_and(node)
      if node.bool_expr && node.bool_expr.boolop == :AND_EXPR
        node.bool_expr.args.flat_map { |arg| flatten_bool_and(arg) }
      else
        [ node ]
      end
    end

    def classify_filter(node)
      if node.null_test
        test = node.null_test
        column = column_name_from_node(test.arg)
        return nil unless column

        op = test.nulltesttype == :IS_NOT_NULL ? "IS NOT NULL" : "IS NULL"
        { column: column, op: op }
      elsif node.a_expr
        expr = node.a_expr
        op = expr.name.map { |n| n.string&.sval }.compact.join
        return nil unless FILTER_COMPARE_OPS.include?(op)

        column = column_name_from_node(expr.lexpr)
        value = const_value(expr.rexpr)
        return nil unless column && !value.nil?

        { column: column, op: op, value: value }
      end
    end

    def classify_time_bound(node, time_column)
      return nil unless node.a_expr

      expr = node.a_expr
      op = expr.name.map { |n| n.string&.sval }.compact.join
      column = column_name_from_node(expr.lexpr)
      return nil unless column == time_column

      if expr.kind == :AEXPR_BETWEEN || op.casecmp("BETWEEN").zero?
        items = expr.rexpr&.list&.items
        raise UnsupportedError, "unsupported BETWEEN bounds on #{time_column}" unless items&.size == 2

        lower = parse_time_value!(items[0], time_column)
        upper = parse_time_value!(items[1], time_column)
        return [
          { edge: :from, value: lower, inclusive: true },
          { edge: :to, value: upper, inclusive: true }
        ]
      end

      return nil unless RANGE_OPS.include?(op)

      value = parse_time_value!(expr.rexpr, time_column)
      case op
      when ">=" then { edge: :from, value: value, inclusive: true }
      when ">"  then { edge: :from, value: value, inclusive: false }
      when "<=" then { edge: :to, value: value, inclusive: true }
      when "<"  then { edge: :to, value: value, inclusive: false }
      end
    end

    def merge_time_bound!(time_range, bound_or_bounds)
      bounds = bound_or_bounds.is_a?(Array) ? bound_or_bounds : [ bound_or_bounds ]
      bounds.each do |bound|
        edge = bound[:edge]
        entry = { value: bound[:value], inclusive: bound[:inclusive] }
        existing = time_range[edge]
        if existing && existing != entry
          raise UnsupportedError, "conflicting time range bounds on #{edge}"
        end
        time_range[edge] = entry
      end
    end

    def parse_time_value!(node, time_column)
      if (literal = const_string(node) || (const_value(node).is_a?(String) ? const_value(node) : nil))
        return { kind: :literal, value: literal }
      end

      if node&.func_call && func_name(node.func_call) == "now" && Array(node.func_call.args).empty?
        return { kind: :now }
      end

      if node&.a_expr
        expr = node.a_expr
        op = expr.name.map { |n| n.string&.sval }.compact.join
        if op == "-" && now_call?(expr.lexpr) && (interval = interval_literal(expr.rexpr))
          return { kind: :now_minus, interval: interval }
        end
        if op == "+" && now_call?(expr.lexpr) && (interval = interval_literal(expr.rexpr))
          return { kind: :now_plus, interval: interval }
        end
      end

      raise UnsupportedError, "unsupported time bound on #{time_column}"
    end

    def now_call?(node)
      node&.func_call && func_name(node.func_call) == "now" && Array(node.func_call.args).empty?
    end

    def interval_literal(node)
      # INTERVAL '1 hour' parses as a TypeCast to pg_catalog.interval
      cast = node&.type_cast
      if cast
        type_names = Array(cast.type_name&.names).filter_map { |n| n.string&.sval }.map(&:downcase)
        return nil unless type_names.include?("interval")

        return const_string(cast.arg)
      end

      const_string(node)
    end

    def column_name_from_node(node)
      return nil if node.nil?

      ref =
        case node
        when PgQuery::ColumnRef then node
        when PgQuery::Node then node.column_ref
        else node.respond_to?(:column_ref) ? node.column_ref : nil
        end
      return nil unless ref

      ref.fields.filter_map { |f| f.string&.sval }.last
    end

    def const_string(node)
      node&.a_const&.sval&.sval
    end

    def const_value(node)
      return nil unless node&.a_const

      c = node.a_const
      return c.sval.sval if c.sval
      return c.ival.ival if c.ival
      return c.fval.fval if c.fval
      return c.boolval.boolval if c.boolval

      nil
    end

    def deparse_expr(node)
      return nil if node.nil?
      return nil unless node.is_a?(PgQuery::Node)

      # Wrap a single expression as SELECT <expr> so pg_query can deparse it.
      select = PgQuery::SelectStmt.new(
        target_list: [
          PgQuery::Node.new(
            res_target: PgQuery::ResTarget.new(
              name: "",
              indirection: [],
              val: node,
              location: -1
            )
          )
        ],
        from_clause: [],
        group_clause: [],
        distinct_clause: [],
        window_clause: [],
        values_lists: [],
        sort_clause: [],
        locking_clause: [],
        op: :SETOP_NONE
      )

      tree = PgQuery::ParseResult.new(
        version: PgQuery::PG_VERSION_NUM,
        stmts: [ PgQuery::RawStmt.new(stmt: PgQuery::Node.new(select_stmt: select)) ]
      )
      PgQuery::ParserResult.new("", tree, []).deparse.sub(/\ASELECT\s+/i, "")
    rescue StandardError
      nil
    end
  end
end
