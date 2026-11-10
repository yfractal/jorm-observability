module GreptimeHelpers
  module_function

  def metric_rows(table_name, dimension_columns = [])
    TraceToMetrics::Injector.summed_rows(table_name, dimension_columns)
  end

  def drop_metric_tables(*names)
    ensure_greptime_connection!
    names.flatten.compact.uniq.each do |name|
      Greptime::Connection.drop_table(name, if_exists: true)
    rescue StandardError
      nil
    end
  end

  def ensure_greptime_connection!
    return if ActiveRecord::Base.connection_pool.connection.active?

    ActiveRecord::Base.establish_connection(:primary)
  rescue StandardError
    ActiveRecord::Base.establish_connection(:primary)
  end

  def cleanup_greptime_data!
    ensure_greptime_connection!

    names =
      begin
        TraceToMetric.unscoped.pluck(:name)
      rescue StandardError
        []
      end
    drop_metric_tables(*names)

    begin
      Greptime::Connection.execute("DELETE FROM trace_to_metrics")
    rescue ActiveRecord::StatementInvalid
      Greptime::Connection.truncate_table("trace_to_metrics") rescue nil
    end

    begin
      Greptime::Connection.truncate_table("traces")
    rescue ActiveRecord::StatementInvalid
      nil
    end
  end
end

RSpec.configure do |config|
  config.include GreptimeHelpers
end
