module TraceToMetrics
  class TableManager
    class Error < StandardError; end

    def self.create!(definition)
      new(definition).create!
    end

    def self.add_dimensions!(definition, new_dimensions)
      new(definition).add_dimensions!(new_dimensions)
    end

    def initialize(definition)
      @definition = definition
      @table_name = definition.name
    end

    def create!
      raise Error, "table name is reserved: #{@table_name}" if reserved?
      raise Error, "table already exists: #{@table_name}" if connection.table_exists?(@table_name)

      dimension_columns = @definition.dimension_columns

      connection.create_table(@table_name) do |t|
        t.timestamptz :bucket, null: false
        dimension_columns.each do |column|
          t.string column
        end
        t.bigint :value, null: false, default: 0
        t.timestamps
      end

      connection.add_index(
        @table_name,
        [ :bucket, *dimension_columns ],
        unique: true,
        name: unique_index_name
      )
    end

    def add_dimensions!(new_dimensions)
      raise Error, "table does not exist: #{@table_name}" unless connection.table_exists?(@table_name)

      sanitized = Array(new_dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
      existing = connection.columns(@table_name).map(&:name)

      connection.transaction do
        sanitized.each do |column|
          next if existing.include?(column)

          connection.add_column(@table_name, column, :string)
        end

        rebuild_unique_index!
      end
    end

    private

    def connection
      ActiveRecord::Base.connection
    end

    def reserved?
      TraceToMetric::RESERVED_TABLE_NAMES.include?(@table_name)
    end

    def unique_index_name
      "index_#{@table_name}_on_bucket_dimensions"
    end

    def rebuild_unique_index!
      if connection.index_exists?(@table_name, name: unique_index_name)
        connection.remove_index(@table_name, name: unique_index_name)
      end

      dimension_columns = @definition.dimension_columns
      connection.add_index(
        @table_name,
        [ :bucket, *dimension_columns ],
        unique: true,
        name: unique_index_name
      )
    end
  end
end
