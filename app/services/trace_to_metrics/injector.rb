module TraceToMetrics
  # Stub for future metric injection from traces.
  class Injector
    def self.call(trace, definition)
      new(trace, definition).call
    end

    def initialize(trace, definition)
      @trace = trace
      @definition = definition
    end

    def call
      # TODO: inject into relative metric table (e.g. upsert-increment
      # #{definition.name} using definition.dimensions from trace attributes)
      nil
    end
  end
end
