# frozen_string_literal: true

module TraceToMetrics
  # Routes live span injection to the matching *Metrics::Injector by metric_type.
  class Injector
    CORE_DIMENSIONS = CounterMetrics::Injector::CORE_DIMENSIONS

    def self.call(trace, definition)
      new(trace, definition).call
    end

    def self.bucket_for(timestamp)
      CounterMetrics::Injector.bucket_for(timestamp)
    end

    def self.summed_rows(table_name, dimension_columns = nil)
      CounterMetrics::Injector.summed_rows(table_name, dimension_columns)
    end

    def initialize(trace, definition)
      @trace = trace
      @definition = definition
    end

    def call
      case @definition.metric_type
      when "counter"
        CounterMetrics::Injector.new(@trace, @definition).call
      when "gauge"
        GaugeMetrics::Injector.call(@trace, @definition)
      when "histogram"
        HistogramMetrics::Injector.new(@trace, @definition).call
      else
        Rails.logger.warn(
          "TraceToMetrics::Injector skipping unsupported metric_type=" \
          "#{@definition.metric_type.inspect} for #{@definition.name}"
        )
      end
      nil
    end
  end
end
