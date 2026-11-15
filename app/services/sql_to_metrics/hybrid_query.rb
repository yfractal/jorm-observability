module SqlToMetrics
  # Runs a COUNT analytics query as metric table + raw traces when coverage allows,
  # otherwise executes the original SQL unchanged.
  class HybridQuery
    Result = Struct.new(:rows, :sql, :used_metric, :metric_name, :segments, keyword_init: true)

    def self.call(sql, use_metric: true)
      new(sql, use_metric: use_metric).call
    end

    def initialize(sql, use_metric: true)
      @sql = sql.to_s
      @use_metric = use_metric
    end

    def call
      if @use_metric
        run_with_metric
      else
        run_direct
      end
    end

    private

    def run_with_metric
      rewritten = QueryRewriter.call(@sql)
      rows = Greptime::Connection.exec_query(rewritten.sql, "SqlToMetrics::HybridQuery").to_a
      Result.new(
        rows: rows,
        sql: rewritten.sql,
        used_metric: rewritten.used_metric,
        metric_name: rewritten.metric_name,
        segments: rewritten.segments
      )
    end

    def run_direct
      rows = Greptime::Connection.exec_query(@sql, "SqlToMetrics::HybridQuery Direct").to_a
      Result.new(
        rows: rows,
        sql: @sql,
        used_metric: false,
        metric_name: nil,
        segments: { metric: nil, raw: [ :all ] }
      )
    end
  end
end
