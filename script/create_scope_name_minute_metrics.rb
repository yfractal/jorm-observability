#!/usr/bin/env ruby
# frozen_string_literal: true

# Create and backfill a 1-minute counter metric grouped by scope_name.
#
#   bin/rails runner script/create_scope_name_minute_metrics.rb

sql = <<~SQL
  SELECT
    date_bin('1 minute', timestamp) AS time,
    scope_name,
    COUNT(*) AS count
  FROM opentelemetry_traces
  GROUP BY scope_name, time
SQL

spec = CounterMetrics::Spec.call(sql)
metric_name = spec[:name]
dimensions = Array(spec[:primary_key])

definition = Struct.new(:name, :dimensions, keyword_init: true) do
  def dimension_columns
    Array(dimensions).map { |d| TraceToMetric.sanitize_dimension(d) }
  end
end.new(name: metric_name, dimensions: spec[:dimensions])

if Greptime::Connection.table_exists?(metric_name)
  Greptime::Connection.truncate_table(metric_name)
else
  TraceToMetrics::TableManager.create!(definition)
end

table = Greptime::Connection.quote_table_name(metric_name)
source = Greptime::Connection.quote_table_name(spec[:source_table])
bucket_column = Greptime::Connection.quote_column_name(spec[:bucket_column] || "timestamp")
select_dims = dimensions.map { |c| Greptime::Connection.quote_column_name(c) }
insert_cols = [ "bucket", *dimensions, "value" ].map { |c|
  Greptime::Connection.quote_column_name(c)
}

select_list = [
  "date_bin('#{spec[:bucket_interval]}', #{bucket_column}) AS bucket",
  *select_dims,
  "COUNT(*) AS value"
].join(", ")

Greptime::Connection.execute(<<~SQL.squish)
  INSERT INTO #{table} (#{insert_cols.join(', ')})
  SELECT #{select_list}
  FROM #{source}
  GROUP BY bucket, #{select_dims.join(', ')}
SQL

rows = Greptime::Connection.exec_query(
  "SELECT count(*) AS c FROM #{table}"
).to_a.first

puts "metric table: #{metric_name}"
puts "dimensions:   #{dimensions.join(', ')}"
puts "rows:         #{rows && (rows['c'] || rows.values.first)}"
