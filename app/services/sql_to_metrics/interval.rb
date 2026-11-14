module SqlToMetrics
  module Interval
    module_function

    UNIT_SECONDS = {
      "second" => 1,
      "seconds" => 1,
      "minute" => 60,
      "minutes" => 60,
      "hour" => 3_600,
      "hours" => 3_600,
      "day" => 86_400,
      "days" => 86_400,
      "week" => 604_800,
      "weeks" => 604_800
    }.freeze

    def seconds(interval)
      text = interval.to_s.strip.downcase
      match = text.match(/\A(\d+)\s+([a-z]+)\z/)
      raise UnsupportedError, "unsupported interval: #{interval.inspect}" unless match

      amount = match[1].to_i
      unit = match[2]
      factor = UNIT_SECONDS[unit]
      raise UnsupportedError, "unsupported interval: #{interval.inspect}" unless factor

      amount * factor
    end

    def multiple?(query_interval, metric_interval)
      q = seconds(query_interval)
      m = seconds(metric_interval)
      m > 0 && q >= m && (q % m).zero?
    end

    def advance(time, interval)
      time + seconds(interval)
    end

    def floor_bucket(time, interval)
      secs = seconds(interval)
      epoch = time.to_i
      Time.at((epoch / secs) * secs).utc
    end

    def ceil_bucket(time, interval)
      floored = floor_bucket(time, interval)
      floored == time ? floored : advance(floored, interval)
    end
  end
end
