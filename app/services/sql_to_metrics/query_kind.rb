# frozen_string_literal: true

module SqlToMetrics
  # Classifies an analytics SQL string as :histogram, :gauge, or :counter.
  module QueryKind
    module_function

    def call(sql)
      return :histogram if HistogramMetrics.histogram_sql?(sql)
      return :gauge if GaugeMetrics::Mapper.gauge_sql?(sql)

      :counter
    end
  end
end
