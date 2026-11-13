class OpentelemetryTrace < ApplicationRecord
  self.table_name = "opentelemetry_traces"
  self.primary_key = [ :trace_id, :span_id ]
  self.record_timestamps = false

  CORE_COLUMNS = %w[
    timestamp
    timestamp_end
    duration_nano
    parent_span_id
    trace_id
    span_id
    span_kind
    span_name
    span_status_code
    span_status_message
    trace_state
    scope_name
    scope_version
    service_name
    span_events
    span_links
  ].freeze

  SPAN_ATTR_PREFIX = "span_attributes."
  RESOURCE_ATTR_PREFIX = "resource_attributes."

  class << self
    def create!(attributes = nil, &block)
      raise ArgumentError, "block form is not supported" if block

      attrs = (attributes || {}).with_indifferent_access.dup
      span_attrs = normalize_attr_hash(attrs.delete(:span_attributes))
      resource_attrs = normalize_attr_hash(attrs.delete(:resource_attributes))
      span_events = attrs.delete(:span_events)
      span_links = attrs.delete(:span_links)

      unknown = attrs.keys.map(&:to_s) - CORE_COLUMNS
      if unknown.any?
        raise ActiveModel::UnknownAttributeError.new(new, unknown.first)
      end

      ensure_attribute_columns!(span_attrs, prefix: SPAN_ATTR_PREFIX)
      ensure_attribute_columns!(resource_attrs, prefix: RESOURCE_ATTR_PREFIX)

      flat = attrs.stringify_keys
      flat["span_events"] = encode_json_column(span_events.nil? ? [] : span_events)
      flat["span_links"] = encode_json_column(span_links.nil? ? [] : span_links)
      span_attrs.each { |key, value| flat["#{SPAN_ATTR_PREFIX}#{key}"] = encode_attr_value(value) }
      resource_attrs.each { |key, value| flat["#{RESOURCE_ATTR_PREFIX}#{key}"] = encode_attr_value(value) }

      insert_flattened!(flat)

      record = instantiate_from_flat(flat, span_attrs, resource_attrs)
      record.send(:enqueue_opentelemetry_trace_created_job)
      record
    end

    def find_by(trace_id: nil, span_id: nil, **rest)
      if rest.empty? && !trace_id.nil? && !span_id.nil?
        return find_by_trace_and_span(trace_id, span_id)
      end

      super
    end

    def find_by!(trace_id: nil, span_id: nil, **rest)
      record = find_by(trace_id: trace_id, span_id: span_id, **rest)
      raise ActiveRecord::RecordNotFound unless record

      record
    end

    def ensure_attribute_columns!(hash, prefix:)
      return if hash.blank?

      existing = Greptime::Connection.column_names(table_name).to_set
      hash.each_key do |key|
        column = "#{prefix}#{key}"
        next if existing.include?(column)

        sql_type = sql_type_for(hash[key])
        Greptime::Connection.execute(
          "ALTER TABLE #{Greptime::Connection.quote_table_name(table_name)} " \
          "ADD COLUMN #{Greptime::Connection.quote_column_name(column)} #{sql_type} NULL"
        )
        existing << column
      end
      reset_column_information
    end

    def normalize_attr_hash(value)
      case value
      when nil then {}
      when Hash then value.stringify_keys
      else
        raise ArgumentError, "expected Hash for attributes, got #{value.class}"
      end
    end

    def encode_json_column(value)
      case value
      when String then value
      else value.to_json
      end
    end

    def encode_attr_value(value)
      case value
      when Hash, Array then value.to_json
      else value
      end
    end

    def sql_type_for(value)
      case value
      when Integer then "BIGINT"
      when Float then "DOUBLE"
      when TrueClass, FalseClass then "BOOLEAN"
      else "STRING"
      end
    end

    def insert_flattened!(flat)
      columns = flat.keys
      quoted_columns = columns.map { |c| Greptime::Connection.quote_column_name(c) }.join(", ")
      placeholders = Array.new(columns.size, "?").join(", ")
      binds = columns.map { |c| cast_bind_value(c, flat[c]) }

      sql = <<~SQL.squish
        INSERT INTO #{Greptime::Connection.quote_table_name(table_name)} (#{quoted_columns})
        VALUES (#{placeholders})
      SQL

      Greptime::Connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([ sql, *binds ]),
        "OpentelemetryTrace Insert"
      )
    end

    def cast_bind_value(column, value)
      case column
      when "timestamp", "timestamp_end"
        value.is_a?(Time) ? value.utc : value
      else
        value
      end
    end

    def find_by_trace_and_span(trace_id, span_id)
      sql = <<~SQL.squish
        SELECT * FROM #{Greptime::Connection.quote_table_name(table_name)}
        WHERE #{Greptime::Connection.quote_column_name("trace_id")} = ?
          AND #{Greptime::Connection.quote_column_name("span_id")} = ?
        LIMIT 1
      SQL
      rows = Greptime::Connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([ sql, trace_id, span_id ]),
        "OpentelemetryTrace Find"
      ).to_a
      return nil if rows.empty?

      instantiate_from_row(rows.first)
    end

    def instantiate_from_flat(flat, span_attrs, resource_attrs)
      record = allocate
      record.send(
        :init_with_attribute_cache,
        flat,
        span_attrs: span_attrs,
        resource_attrs: resource_attrs
      )
      record
    end

    def instantiate_from_row(row)
      row = row.stringify_keys
      span_attrs = {}
      resource_attrs = {}
      row.each do |name, value|
        next if value.nil?

        if name.start_with?(SPAN_ATTR_PREFIX)
          span_attrs[name.delete_prefix(SPAN_ATTR_PREFIX)] = value
        elsif name.start_with?(RESOURCE_ATTR_PREFIX)
          resource_attrs[name.delete_prefix(RESOURCE_ATTR_PREFIX)] = value
        end
      end

      instantiate_from_flat(row, span_attrs, resource_attrs)
    end
  end

  def span_attributes
    @span_attributes_cache || {}
  end

  def resource_attributes
    @resource_attributes_cache || {}
  end

  def span_events
    decode_json_column(read_core("span_events")) || []
  end

  def span_links
    decode_json_column(read_core("span_links")) || []
  end

  def timestamp
    read_core("timestamp")
  end

  def timestamp_end
    read_core("timestamp_end")
  end

  def duration_nano
    read_core("duration_nano")
  end

  def parent_span_id
    read_core("parent_span_id")
  end

  def trace_id
    read_core("trace_id")
  end

  def span_id
    read_core("span_id")
  end

  def span_kind
    read_core("span_kind")
  end

  def span_name
    read_core("span_name")
  end

  def span_status_code
    read_core("span_status_code")
  end

  def span_status_message
    read_core("span_status_message")
  end

  def trace_state
    read_core("trace_state")
  end

  def scope_name
    read_core("scope_name")
  end

  def scope_version
    read_core("scope_version")
  end

  def service_name
    read_core("service_name")
  end

  def persisted?
    @persisted == true
  end

  def new_record?
    !persisted?
  end

  def ==(other)
    other.is_a?(self.class) &&
      trace_id == other.trace_id &&
      span_id == other.span_id
  end
  alias eql? ==

  def hash
    [ self.class, trace_id, span_id ].hash
  end

  private

  def init_with_attribute_cache(flat, span_attrs:, resource_attrs:)
    @flat_attributes = flat.stringify_keys
    @span_attributes_cache = span_attrs.stringify_keys
    @resource_attributes_cache = resource_attrs.stringify_keys
    @persisted = true
    @new_record = false
  end

  def read_core(name)
    @flat_attributes&.[](name.to_s)
  end

  def decode_json_column(value)
    case value
    when nil then nil
    when Hash, Array then value
    when String
      JSON.parse(value)
    else
      value
    end
  rescue JSON::ParserError
    value
  end

  def enqueue_opentelemetry_trace_created_job
    OpentelemetryTraceCreatedJob.perform_later(trace_id, span_id)
  end
end
