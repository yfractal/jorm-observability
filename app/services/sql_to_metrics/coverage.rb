module SqlToMetrics
  class Coverage
    def self.call(metric_name, bucket_interval:, now: Time.now.utc)
      new(metric_name, bucket_interval: bucket_interval, now: now).call
    end

    def initialize(metric_name, bucket_interval:, now: Time.now.utc)
      @metric_name = metric_name
      @bucket_interval = bucket_interval
      @now = now
    end

    # Returns a half-open coverage window [from, to) of complete buckets.
    # Historical buckets are trusted; only the current open bucket (floor(now))
    # is treated as possibly partial and excluded.
    def call
      return nil unless Greptime::Connection.table_exists?(@metric_name)

      table = Greptime::Connection.quote_table_name(@metric_name)
      row = Greptime::Connection.exec_query(
        "SELECT MIN(bucket) AS min_bucket, MAX(bucket) AS max_bucket FROM #{table}",
        "SqlToMetrics::Coverage"
      ).to_a.first

      return nil if row.nil?

      min_bucket = parse_time(row["min_bucket"] || row.values[0])
      max_bucket = parse_time(row["max_bucket"] || row.values[1])
      return nil if min_bucket.nil? || max_bucket.nil?

      open_bucket = Interval.floor_bucket(@now.utc, @bucket_interval)
      from = min_bucket
      to = [ Interval.advance(max_bucket, @bucket_interval), open_bucket ].min
      return nil unless from < to

      { from: from, to: to }
    end

    private

    def parse_time(value)
      case value
      when nil then nil
      when Time then value.utc
      when DateTime then value.to_time.utc
      when Date then value.to_time.utc
      else
        Time.parse(value.to_s).utc
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
