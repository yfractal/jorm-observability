require "json"
require "net/http"
require "uri"
require "tmpdir"
require "fileutils"

namespace :greptime do
  desc "Apply GreptimeDB primary schema (opentelemetry_traces, trace_to_metrics)"
  task prepare: :environment do
    Greptime::Schema.load!
    puts "GreptimeDB primary schema ready"
  end

  desc "Import opentelemetry_traces from a source GreptimeDB via Parquet COPY"
  task import_opentelemetry_traces: :environment do
    source_http = ENV.fetch("SOURCE_GREPTIME_HTTP", "http://localhost:14010")
    source_db = ENV.fetch("SOURCE_DB", "lobsters")
    source_table = ENV.fetch("SOURCE_TABLE", "opentelemetry_traces")
    dest_http = ENV.fetch("DEST_GREPTIME_HTTP", "http://localhost:4000")
    dest_db = ENV.fetch("DEST_DB", "public")
    dest_table = ENV.fetch("DEST_TABLE", "opentelemetry_traces")
    source_container = ENV.fetch("SOURCE_GREPTIME_CONTAINER", "jorm-greptimedb-1")
    dest_container = ENV.fetch("DEST_GREPTIME_CONTAINER", "jorm-observability-greptimedb-1")
    parquet_name = ENV.fetch("PARQUET_NAME", "opentelemetry_traces.parquet")
    copy_root = ENV.fetch("GREPTIME_COPY_ROOT", "/greptimedb_data/copy")

    Greptime::Schema.load!

    source_count = greptime_sql_value(
      source_http, source_db,
      "SELECT count(*) AS c FROM #{source_table}"
    ).to_i
    puts "Source #{source_db}.#{source_table}: #{source_count} rows"

    puts "Exporting #{source_table} → #{parquet_name} on #{source_container}…"
    greptime_sql!(
      source_http, source_db,
      "COPY #{source_table} TO '#{parquet_name}' WITH (FORMAT = 'parquet')"
    )

    Dir.mktmpdir("otel-import") do |dir|
      host_parquet = File.join(dir, parquet_name)
      source_path = File.join(copy_root, parquet_name)
      dest_path = File.join(copy_root, parquet_name)

      puts "docker cp #{source_container}:#{source_path} → host"
      system("docker", "cp", "#{source_container}:#{source_path}", host_parquet, exception: true)

      puts "docker cp host → #{dest_container}:#{dest_path}"
      system("docker", "exec", dest_container, "mkdir", "-p", copy_root, exception: true)
      system("docker", "cp", host_parquet, "#{dest_container}:#{dest_path}", exception: true)
    end

    puts "Importing #{parquet_name} → #{dest_db}.#{dest_table}…"
    greptime_sql!(
      dest_http, dest_db,
      "COPY #{dest_table} FROM '#{parquet_name}' WITH (FORMAT = 'parquet')"
    )

    dest_count = greptime_sql_value(
      dest_http, dest_db,
      "SELECT count(*) AS c FROM #{dest_table}"
    ).to_i
    puts "Destination #{dest_db}.#{dest_table}: #{dest_count} rows"

    if dest_count != source_count
      abort "Import count mismatch: source=#{source_count} dest=#{dest_count}"
    end

    puts "Import complete (#{dest_count} rows)"
  end
end

# Hook into db:prepare so Docker/local bootstraps Greptime + queue together.
Rake::Task["db:prepare"].enhance([ "greptime:prepare" ]) if Rake::Task.task_defined?("db:prepare")

def greptime_sql!(http_base, db, sql)
  uri = URI("#{http_base}/v1/sql")
  uri.query = URI.encode_www_form(db: db, sql: sql)
  response = Net::HTTP.get_response(uri)
  body = JSON.parse(response.body)
  if body["error"]
    raise "Greptime SQL error on #{http_base} (db=#{db}): #{body["error"]}\nSQL: #{sql}"
  end
  body
end

def greptime_sql_value(http_base, db, sql)
  body = greptime_sql!(http_base, db, sql)
  body.dig("output", 0, "records", "rows", 0, 0)
end
