module HistogramMetrics
  # bucket (time index) | dimension tags | sketch (UDDSketch state, BINARY)
  #
  # Append-only like counters: backfill chunks and live spans each add rows for the
  # same (bucket, dimensions); readers merge them with uddsketch_merge.
  class Table
    def self.create!(definition)
      connection = Greptime::Connection
      dimension_columns = definition.dimension_columns
      quoted_dims = dimension_columns.map { |c| connection.quote_column_name(c) }

      columns = [
        "#{connection.quote_column_name('bucket')} TIMESTAMP TIME INDEX",
        *quoted_dims.map { |c| "#{c} STRING" },
        "#{connection.quote_column_name(SKETCH_COLUMN)} BINARY"
      ]
      primary_key = quoted_dims.empty? ? nil : "PRIMARY KEY (#{quoted_dims.join(', ')})"
      body = [ *columns, primary_key ].compact.join(", ")

      connection.execute(<<~SQL.squish)
        CREATE TABLE #{connection.quote_table_name(definition.name)} (#{body}) WITH ('append_mode'='true')
      SQL
    end
  end
end
