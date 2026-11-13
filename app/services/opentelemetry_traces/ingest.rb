require "base64"

module OpentelemetryTraces
  class Ingest
    Result = Data.define(:traces, :count)

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
    end

    def call
      created = []

      Array(@payload[:resourceSpans]).each do |resource_span|
        resource_span = resource_span.with_indifferent_access
        resource_attributes = flatten_attributes(resource_span.dig(:resource, :attributes))
        service_name = resource_attributes["service.name"] || resource_attributes[:service_name]

        Array(resource_span[:scopeSpans]).each do |scope_span|
          scope_span = scope_span.with_indifferent_access
          scope = scope_span[:scope]&.with_indifferent_access || {}

          Array(scope_span[:spans]).each do |raw_span|
            created << create_trace!(
              raw_span.with_indifferent_access,
              service_name: service_name,
              resource_attributes: resource_attributes,
              scope_name: scope[:name],
              scope_version: scope[:version]
            )
          end
        end
      end

      Result.new(traces: created, count: created.size)
    end

    private

    def create_trace!(raw, service_name:, resource_attributes:, scope_name:, scope_version:)
      start_ns = parse_nano(raw[:startTimeUnixNano])
      end_ns = parse_nano(raw[:endTimeUnixNano])
      duration = if start_ns && end_ns
        end_ns - start_ns
      else
        parse_nano(raw[:durationNano] || raw[:duration_nano])
      end

      OpentelemetryTrace.create!(
        timestamp: nano_to_time(start_ns) || Time.current,
        timestamp_end: nano_to_time(end_ns),
        duration_nano: duration,
        parent_span_id: hex_id(raw[:parentSpanId]),
        trace_id: hex_id(raw[:traceId]),
        span_id: hex_id(raw[:spanId]),
        span_kind: span_kind_name(raw[:kind]),
        span_name: raw[:name],
        span_status_code: status_code_name(raw.dig(:status, :code)),
        span_status_message: raw.dig(:status, :message),
        trace_state: raw[:traceState],
        scope_name: scope_name,
        scope_version: scope_version,
        service_name: service_name,
        span_attributes: flatten_attributes(raw[:attributes]),
        resource_attributes: resource_attributes,
        span_events: Array(raw[:events]).map { |e| normalize_event(e) },
        span_links: Array(raw[:links]).map { |l| normalize_link(l) }
      )
    end

    def flatten_attributes(attributes)
      Array(attributes).each_with_object({}) do |attr, memo|
        attr = attr.with_indifferent_access
        key = attr[:key]
        next if key.blank?

        memo[key.to_s] = attribute_value(attr[:value])
      end
    end

    def attribute_value(value)
      return nil if value.nil?

      value = value.with_indifferent_access if value.is_a?(Hash)

      case
      when value.key?(:stringValue) then value[:stringValue]
      when value.key?(:intValue) then value[:intValue].to_i
      when value.key?(:doubleValue) then value[:doubleValue].to_f
      when value.key?(:boolValue) then value[:boolValue]
      when value.key?(:bytesValue) then value[:bytesValue]
      when value.key?(:arrayValue)
        Array(value.dig(:arrayValue, :values)).map { |v| attribute_value(v) }
      when value.key?(:kvlistValue)
        Array(value.dig(:kvlistValue, :values)).each_with_object({}) do |kv, memo|
          kv = kv.with_indifferent_access
          memo[kv[:key].to_s] = attribute_value(kv[:value])
        end
      else
        value
      end
    end

    def parse_nano(value)
      return nil if value.nil? || value == ""

      value.to_i
    end

    def nano_to_time(nano)
      return nil if nano.nil?

      Time.at(0, nano, :nanosecond).utc
    end

    def hex_id(value)
      return nil if value.nil? || value == ""
      return value if value.match?(/\A[0-9a-fA-F]+\z/)

      # OTLP JSON may encode ids as base64
      begin
        Base64.decode64(value).unpack1("H*")
      rescue ArgumentError
        value
      end
    end

    def span_kind_name(kind)
      case kind.to_s
      when "1", "SPAN_KIND_INTERNAL", "INTERNAL" then "INTERNAL"
      when "2", "SPAN_KIND_SERVER", "SERVER" then "SERVER"
      when "3", "SPAN_KIND_CLIENT", "CLIENT" then "CLIENT"
      when "4", "SPAN_KIND_PRODUCER", "PRODUCER" then "PRODUCER"
      when "5", "SPAN_KIND_CONSUMER", "CONSUMER" then "CONSUMER"
      else
        kind.presence || "UNSPECIFIED"
      end
    end

    def status_code_name(code)
      case code.to_s
      when "1", "STATUS_CODE_OK", "OK" then "OK"
      when "2", "STATUS_CODE_ERROR", "ERROR" then "ERROR"
      else
        "UNSET"
      end
    end

    def normalize_event(event)
      event = event.with_indifferent_access
      {
        "name" => event[:name],
        "time_unix_nano" => event[:timeUnixNano],
        "attributes" => flatten_attributes(event[:attributes])
      }
    end

    def normalize_link(link)
      link = link.with_indifferent_access
      {
        "trace_id" => hex_id(link[:traceId]),
        "span_id" => hex_id(link[:spanId]),
        "trace_state" => link[:traceState],
        "attributes" => flatten_attributes(link[:attributes])
      }
    end
  end
end
