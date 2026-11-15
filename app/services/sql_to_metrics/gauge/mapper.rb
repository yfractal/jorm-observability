# frozen_string_literal: true

require "pg_query"

module SqlToMetrics
  module Gauge
    # Maps AVG(col) [ / const ] analytics queries to a gauge metric shape.
    # Reuses counter Mapper filter / time-range / date_bin parsing.
    class Mapper < SqlToMetrics::Mapper
      GAUGE_FUNCS = %w[avg].freeze

      def self.gauge_sql?(sql)
        sql.to_s.match?(/\bavg\s*\(/i)
      end

      private

      def classify_res_target(res_target)
        alias_name = res_target.name.presence
        val = res_target.val

        if (avg = extract_avg(val))
          {
            alias: alias_name,
            kind: :agg,
            func: "avg",
            column: avg[:column],
            scale: avg[:scale],
            distinct: false,
            args: [ avg[:column] ]
          }
        elsif (func = val&.func_call) && time_bucket_func?(func)
          interval, column = time_bucket_args(func)
          {
            alias: alias_name,
            kind: :time_bucket,
            interval: interval,
            column: column
          }
        else
          {
            alias: alias_name || column_name_from_node(val),
            kind: :other,
            expr: deparse_expr(val)
          }
        end
      end

      def metric_type_for(res_targets)
        return "gauge" if res_targets.any? { |t| t[:kind] == :agg && t[:func] == "avg" }

        nil
      end

      # AVG(col) or AVG(col) / const  (const is a multiplicative scale, e.g. 1e6)
      def extract_avg(node)
        return nil if node.nil?

        if node.func_call && gauge_func?(node.func_call)
          column = avg_column(node.func_call)
          return nil if column.nil?

          return { column: column, scale: nil }
        end

        return nil unless node.a_expr

        expr = node.a_expr
        op = expr.name.map { |n| n.string&.sval }.compact.join
        return nil unless op == "/"

        left = extract_avg(expr.lexpr)
        return nil if left.nil? || left[:scale]

        divisor = const_value(expr.rexpr)
        return nil if divisor.nil? || !numeric?(divisor)

        { column: left[:column], scale: divisor.to_f }
      end

      def gauge_func?(func)
        GAUGE_FUNCS.include?(func_name(func))
      end

      def avg_column(func)
        return nil if func.agg_star

        args = Array(func.args)
        return nil unless args.size == 1

        column_name_from_node(args.first) || deparse_expr(args.first)
      end

      def numeric?(value)
        value.is_a?(Numeric) || value.to_s.match?(/\A[-+]?\d+(\.\d+)?([eE][-+]?\d+)?\z/)
      end
    end
  end
end
