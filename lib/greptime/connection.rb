module Greptime
  module Connection
    module_function

    def raw
      ActiveRecord::Base.connection
    end

    def execute(sql, name = "Greptime SQL")
      raw.execute(sql, name)
    end

    def exec_query(sql, name = "Greptime SQL", binds = [])
      if binds.empty?
        raw.exec_query(sql, name)
      else
        raw.exec_query(
          ActiveRecord::Base.sanitize_sql_array([ sql, *binds ]),
          name
        )
      end
    end

    def quote_table_name(name)
      raw.quote_table_name(name)
    end

    def quote_column_name(name)
      raw.quote_column_name(name)
    end

    def quote(value)
      raw.quote(value)
    end

    def table_exists?(table_name)
      result = exec_query(
        "SELECT table_name FROM information_schema.tables WHERE table_name = ?",
        "Greptime table_exists?",
        [ table_name.to_s ]
      )
      result.any?
    rescue ActiveRecord::StatementInvalid
      # Fallback for Greptime builds without information_schema.tables.
      result = execute("SHOW TABLES")
      names = result.respond_to?(:to_a) ? result.to_a.flatten.map(&:to_s) : []
      names.include?(table_name.to_s)
    end

    def column_names(table_name)
      result = exec_query(
        "SELECT column_name FROM information_schema.columns WHERE table_name = ? ORDER BY ordinal_position",
        "Greptime columns",
        [ table_name.to_s ]
      )
      result.map { |row| row["column_name"] || row.values.first }
    rescue ActiveRecord::StatementInvalid
      result = execute("DESC #{quote_table_name(table_name)}")
      Array(result).map { |row| row.is_a?(Hash) ? (row["Field"] || row["column_name"] || row.values.first) : Array(row).first }.map(&:to_s)
    end

    def drop_table(table_name, if_exists: true)
      suffix = if_exists ? "IF EXISTS" : ""
      execute("DROP TABLE #{suffix} #{quote_table_name(table_name)}".squish)
    end

    def truncate_table(table_name)
      execute("TRUNCATE TABLE #{quote_table_name(table_name)}")
    end
  end
end
