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

    def call
      select = select_stmt!
      res_targets = select.target_list.map { |node| classify_res_target(node.res_target) }
      time_bucket = extract_time_bucket(res_targets)
      {
        metric_type: metric_type_for(res_targets),
        dimensions: extract_dimensions(select, time_bucket),
        time_bucket: time_bucket,
        res_targets: res_targets,
        filters: extract_filters(select.where_clause)
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
      return [] if where_node.nil?

      flatten_bool_and(where_node).filter_map { |node| classify_filter(node) }
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
        return nil unless op == "="

        column = column_name_from_node(expr.lexpr)
        value = const_value(expr.rexpr)
        return nil unless column && !value.nil?

        { column: column, op: "=", value: value }
      end
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
