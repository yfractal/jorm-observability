module SqlToMetrics
  class Runner
    Result = Struct.new(:rows, :sql, :used_metric, :metric_name, :segments, keyword_init: true)

    def self.call(sql)
      new(sql).call
    end

    def initialize(sql)
      @sql = sql.to_s
    end

    def call
      rewritten = QueryRewriter.call(@sql)
      rows = Greptime::Connection.exec_query(rewritten.sql, "SqlToMetrics::Runner").to_a
      Result.new(
        rows: rows,
        sql: rewritten.sql,
        used_metric: rewritten.used_metric,
        metric_name: rewritten.metric_name,
        segments: rewritten.segments
      )
    end
  end
end
