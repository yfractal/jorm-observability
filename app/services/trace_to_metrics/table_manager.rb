module TraceToMetrics
  class TableManager
    class Error < StandardError; end

    def self.create!(definition)
      return Gauge::TableManager.create!(definition) if gauge_definition?(definition)

      new(definition).create!
    end

    def self.add_dimensions!(definition, new_dimensions)
      return Gauge::TableManager.add_dimensions!(definition, new_dimensions) if gauge_definition?(definition)

      new(definition).add_dimensions!(new_dimensions)
    end

    def self.gauge_definition?(definition)
      definition.respond_to?(:metric_type) && definition.metric_type == "gauge"
    end
    private_class_method :gauge_definition?

    def initialize(definition)
      @definition = definition
      @table_name = definition.name
    end

    def create!
      raise Error, "table name is reserved: #{@table_name}" if reserved?
      raise Error, "table already exists: #{@table_name}" if Greptime::Connection.table_exists?(@table_name)

      dimension_columns = @definition.dimension_columns
      quoted_table = Greptime::Connection.quote_table_name(@table_name)

      dimension_ddl = dimension_columns.map { |column|
        "#{Greptime::Connection.quote_column_name(column)} STRING"
      }

      columns = [
        "#{Greptime::Connection.quote_column_name('bucket')} TIMESTAMP TIME INDEX",
        *dimension_ddl,
        "#{Greptime::Connection.quote_column_name('value')} BIGINT"
      ]

      primary_key =
        if dimension_columns.empty?
          nil
        else
          "PRIMARY KEY (#{dimension_columns.map { |c| Greptime::Connection.quote_column_name(c) }.join(', ')})"
        end

      body = [ *columns, primary_key ].compact.join(", ")

      sql = <<~SQL.squish
        CREATE TABLE #{quoted_table} (
          #{body}
        ) WITH ('append_mode'='true')
      SQL

      Greptime::Connection.execute(sql)
    end

    def add_dimensions!(new_dimensions)
      raise Error, "table does not exist: #{@table_name}" unless Greptime::Connection.table_exists?(@table_name)

      sanitized = Array(new_dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      existing = Greptime::Connection.column_names(@table_name)
      quoted_table = Greptime::Connection.quote_table_name(@table_name)

      sanitized.each do |column|
        next if existing.include?(column)

        quoted_column = Greptime::Connection.quote_column_name(column)
        # Dimension columns are tags (PRIMARY KEY). Greptime requires DEFAULT when
        # adding a tag to an existing table.
        Greptime::Connection.execute(<<~SQL.squish)
          ALTER TABLE #{quoted_table}
          ADD COLUMN #{quoted_column} STRING DEFAULT '' PRIMARY KEY
        SQL
      end
    end

    private

    def reserved?
      TraceToMetric::RESERVED_TABLE_NAMES.include?(@table_name)
    end
  end
end
