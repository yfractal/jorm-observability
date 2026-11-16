# frozen_string_literal: true

module SqlToMetrics
  # Classifies an analytics SQL string as :histogram, :gauge, :counter, or :unsupported.
  module QueryKind
    module_function

    def call(sql)
      return :histogram if HistogramMetrics.histogram_sql?(sql)
      return :gauge if GaugeMetrics.gauge_sql?(sql)
      return :counter if CounterMetrics.counter_sql?(sql)

      :unsupported
    end
  end
end
