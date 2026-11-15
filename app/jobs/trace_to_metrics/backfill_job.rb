module TraceToMetrics
  class BackfillJob < ApplicationJob
    queue_as :default

    # Process one hour of spans per INSERT so bin/jobs can show progress.
    CHUNK = 1.hour

    def perform(metric_name)
      definition = TraceToMetric.find_by(name: metric_name)
      unless definition&.query_metric?
        log("skip #{metric_name.inspect}: not a query metric")
        return
      end
      if definition.backfill_finished?
        log("skip #{metric_name}: already finished at #{definition.backfill_finished_at}")
        return
      end
      unless definition.watermark_ready?
        log("skip #{metric_name}: watermark not ready")
        return
      end

      log(
        "start #{metric_name} through " \
        "#{definition.backfill_through_timestamp.utc.iso8601} " \
        "trace=#{definition.backfill_through_trace_id} span=#{definition.backfill_through_span_id}"
      )

      ranges = chunk_ranges(definition)
      if ranges.empty?
        log("#{metric_name}: no spans to backfill")
      else
        log("#{metric_name}: #{ranges.size} chunk(s)")
        ranges.each_with_index do |range, index|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          insert_aggregated!(definition, from: range[:from], to: range[:to])
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          log(
            format(
              "%s: chunk %d/%d %s .. %s (%.1fs)",
              metric_name,
              index + 1,
              ranges.size,
              range[:from].utc.strftime("%Y-%m-%d %H:%M:%S"),
              range[:to].utc.strftime("%Y-%m-%d %H:%M:%S"),
              elapsed
            )
          )
        end
      end

      rows = metric_row_count(definition.name)
      definition.update_columns(backfill_finished_at: Time.now.utc)
      log("done #{metric_name}: #{rows} metric row(s), finished_at=#{definition.backfill_finished_at.utc.iso8601}")
    end

    private

    def log(message)
      line = "[TraceToMetrics::BackfillJob] #{message}"
      Rails.logger.info(line)
      $stdout.puts(line)
      $stdout.flush
    end

    def chunk_ranges(definition)
      connection = Greptime::Connection
      where = watermark_and_filters_sql(definition)
      row = connection.exec_query(<<~SQL.squish, "TraceToMetrics::BackfillJob Range").to_a.first
        SELECT MIN(timestamp) AS min_ts, MAX(timestamp) AS max_ts
        FROM opentelemetry_traces
        WHERE #{where}
      SQL
      return [] if row.nil?

      min_ts = parse_time(row["min_ts"] || row.values[0])
      max_ts = parse_time(row["max_ts"] || row.values[1])
      return [] if min_ts.nil? || max_ts.nil?

      watermark = definition.backfill_through_timestamp.utc
      end_at = [ max_ts, watermark ].min + Rational(1, 1_000_000)
      cursor = min_ts.utc.beginning_of_hour
      ranges = []
      while cursor < end_at
        nxt = [ cursor + CHUNK, end_at ].min
        ranges << { from: cursor, to: nxt }
        cursor = nxt
      end
      ranges
    end

    def insert_aggregated!(definition, from:, to:)
      connection = Greptime::Connection
      table = connection.quote_table_name(definition.name)
      source = connection.quote_table_name("opentelemetry_traces")
      interval = definition.bucket_interval.presence || "1 minute"
      dimensions = Array(definition.dimensions)
      dim_cols = dimensions.map { |d| TraceToMetric.sanitize_dimension(d) }
      quoted_dims = dimensions.map { |d| connection.quote_column_name(d) }
      quoted_dim_aliases = dim_cols.map { |c| connection.quote_column_name(c) }

      select_dims =
        if dimensions.empty?
          []
        else
          dimensions.each_with_index.map do |raw, i|
            "#{connection.quote_column_name(raw)} AS #{quoted_dim_aliases[i]}"
          end
        end

      insert_cols = [ "bucket", *dim_cols, "value" ].map { |c| connection.quote_column_name(c) }
      select_list = [
        "date_bin(#{connection.quote(interval)}, timestamp) AS bucket",
        *select_dims,
        "COUNT(*) AS value"
      ].join(", ")

      group_list = [ "bucket", *quoted_dims ].join(", ")
      where = [
        watermark_and_filters_sql(definition),
        "timestamp >= #{connection.quote(from.utc.strftime('%Y-%m-%d %H:%M:%S.%6N'))}",
        "timestamp < #{connection.quote(to.utc.strftime('%Y-%m-%d %H:%M:%S.%6N'))}"
      ].join(" AND ")

      return HistogramMetrics::Backfill.insert_chunk!(definition, where_sql: where) if definition.metric_type == "histogram"

      connection.execute(<<~SQL.squish)
        INSERT INTO #{table} (#{insert_cols.join(', ')})
        SELECT #{select_list}
        FROM #{source}
        WHERE #{where}
        GROUP BY #{group_list}
      SQL
    end

    def metric_row_count(metric_name)
      table = Greptime::Connection.quote_table_name(metric_name)
      row = Greptime::Connection.exec_query(
        "SELECT COUNT(*) AS c FROM #{table}",
        "TraceToMetrics::BackfillJob Count"
      ).to_a.first
      (row && (row["c"] || row.values.first)).to_i
    end

    def watermark_and_filters_sql(definition)
      connection = Greptime::Connection
      ts = definition.backfill_through_timestamp.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
      parts = [
        "(timestamp < #{connection.quote(ts)}" \
          " OR (timestamp = #{connection.quote(ts)}" \
          " AND trace_id < #{connection.quote(definition.backfill_through_trace_id.to_s)})" \
          " OR (timestamp = #{connection.quote(ts)}" \
          " AND trace_id = #{connection.quote(definition.backfill_through_trace_id.to_s)}" \
          " AND span_id <= #{connection.quote(definition.backfill_through_span_id.to_s)}))"
      ]

      Array(definition.filters).each do |filter|
        column = filter["column"] || filter[:column]
        op = filter["op"] || filter[:op]
        value = filter.key?("value") ? filter["value"] : filter[:value]
        quoted = connection.quote_column_name(column)
        parts <<
          case op
          when "IS NULL" then "#{quoted} IS NULL"
          when "IS NOT NULL" then "#{quoted} IS NOT NULL"
          when "=", "<", "<=", ">", ">="
            "#{quoted} #{op} #{quote_filter_value(connection, value)}"
          when SqlToMetrics::Mapper::NULL_OR_NOT_EQUAL_OP
            "(#{quoted} IS NULL OR #{quoted} != #{quote_filter_value(connection, value)})"
          else "TRUE"
          end
      end

      parts.join(" AND ")
    end

    def quote_filter_value(connection, value)
      case value
      when Integer, Float then value.to_s
      when TrueClass then "TRUE"
      when FalseClass then "FALSE"
      else connection.quote(value.to_s)
      end
    end

    def parse_time(value)
      case value
      when nil then nil
      when Time then value.utc
      when DateTime then value.to_time.utc
      else Time.parse(value.to_s).utc
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
