module SpanToMetrics
  # Stub for future metric injection from spans.
  class Injector
    def self.call(span, definition)
      new(span, definition).call
    end

    def initialize(span, definition)
      @span = span
      @definition = definition
    end

    def call
      # TODO: inject into relative metric table (e.g. upsert-increment
      # #{definition.name} using definition.dimensions from span attributes)
      nil
    end
  end
end
