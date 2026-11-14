require "pg_query"

module SqlQuery
  class ReadOnly
    class Error < StandardError; end

    def self.validate!(sql)
      new(sql).validate!
    end

    def initialize(sql)
      @sql = sql.to_s.strip
    end

    def validate!
      raise Error, "sql is required" if @sql.blank?

      tree = PgQuery.parse(@sql).tree
      raise Error, "expected a single statement" unless tree.stmts.size == 1

      select = tree.stmts.first.stmt.select_stmt
      raise Error, "only SELECT queries are allowed" unless select
      raise Error, "SELECT INTO is not allowed" if select.into_clause
      raise Error, "only read-only WITH clauses are allowed" if modifying_cte?(select)

      @sql
    rescue PgQuery::ParseError => e
      raise Error, e.message
    end

    private

    def modifying_cte?(select)
      ctes = select.with_clause&.ctes
      return false if ctes.blank?

      ctes.any? { |cte| cte.common_table_expr.ctequery.select_stmt.nil? }
    end
  end
end
