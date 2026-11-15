#!/usr/bin/env ruby
# frozen_string_literal: true

# Drop SQL-derived query counter/gauge metrics (tables + trace_to_metrics rows).
#
#   bin/rails runner script/drop_query_metrics.rb

QUERY_TABLE_PREFIX = "opentelemetry_traces"

def listed_tables
  result = Greptime::Connection.execute("SHOW TABLES")
  rows = result.respond_to?(:to_a) ? result.to_a : Array(result)
  rows.filter_map do |row|
    name = row.is_a?(Hash) ? (row["Tables_in_public"] || row["table_name"] || row.values.first) : Array(row).first
    name.to_s.presence
  end
end

def query_metric_table?(name)
  return false if name == "opentelemetry_traces" || name == "trace_to_metrics"

  name.start_with?("#{QUERY_TABLE_PREFIX}_") &&
    (name.end_with?("_counter") || name.end_with?("_gauge"))
end

names = TraceToMetric.query_metrics.pluck(:name)
orphan_tables = listed_tables.select { |name| query_metric_table?(name) }
to_drop = (names + orphan_tables).uniq.sort

if to_drop.empty?
  puts "No query metrics to drop."
  exit
end

puts "Dropping #{to_drop.size} query metric(s):"
to_drop.each do |name|
  Greptime::Connection.drop_table(name, if_exists: true)
  puts "  dropped table #{name}"
end

meta_names = TraceToMetric.query_metrics.to_a.map(&:name)
table = Greptime::Connection.quote_table_name("trace_to_metrics")
meta_names.each do |name|
  Greptime::Connection.execute(
    "DELETE FROM #{table} WHERE #{Greptime::Connection.quote_column_name('name')} = #{Greptime::Connection.quote(name)}"
  )
  puts "  deleted meta #{name}"
end

puts "Done. tables=#{to_drop.size} meta_rows=#{meta_names.size}"
