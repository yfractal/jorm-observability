# frozen_string_literal: true

module TraceToMetrics
  # Routes metric table DDL to the matching *Metrics::Table by metric_type.
  class TableManager
    class Error < StandardError; end

    def self.create!(definition)
      case metric_type(definition)
      when "gauge" then GaugeMetrics::Table.create!(definition)
      when "histogram" then HistogramMetrics::Table.create!(definition)
      else CounterMetrics::Table.create!(definition)
      end
    rescue CounterMetrics::Table::Error, GaugeMetrics::Table::Error => e
      raise Error, e.message
    end

    def self.add_dimensions!(definition, new_dimensions)
      case metric_type(definition)
      when "gauge" then GaugeMetrics::Table.add_dimensions!(definition, new_dimensions)
      when "histogram"
        raise Error, "histogram metrics do not support add_dimensions!"
      else CounterMetrics::Table.add_dimensions!(definition, new_dimensions)
      end
    rescue CounterMetrics::Table::Error, GaugeMetrics::Table::Error => e
      raise Error, e.message
    end

    def self.metric_type(definition)
      definition.respond_to?(:metric_type) ? definition.metric_type : "counter"
    end
    private_class_method :metric_type
  end
end
