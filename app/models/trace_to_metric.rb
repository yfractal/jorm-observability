class TraceToMetric < ApplicationRecord
  self.primary_key = "name"
  self.record_timestamps = false

  METRIC_TYPES = %w[counter].freeze
  NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/
  QUERY_SPAN_NAME = "query"
  STABLE_GREPTIME_TS = Time.utc(1970, 1, 1)
  RESERVED_TABLE_NAMES = %w[
    opentelemetry_traces
    trace_to_metrics
    schema_migrations
    ar_internal_metadata
    solid_queue_jobs
    solid_cache_entries
    solid_cable_messages
  ].freeze

  serialize :dimensions, coder: JSON
  serialize :filters, coder: JSON

  before_validation :derive_name, on: :create
  before_validation :normalize_dimensions
  before_validation :normalize_filters
  before_validation :ensure_greptime_ts
  before_validation :ensure_version

  validates :span_name, presence: true
  validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
  validates :name, presence: true, format: { with: NAME_FORMAT }
  validate :name_must_be_unique, on: :create
  validate :name_matches_convention
  validate :name_not_reserved
  validate :dimensions_are_valid
  validate :dimensions_only_added, on: :update

  after_create :create_metric_table!
  after_update :evolve_metric_table!, if: :saved_change_to_dimensions?

  def self.for_span_name(span_name)
    where.not(span_name: QUERY_SPAN_NAME).find_by(span_name: span_name)
  end

  def self.query_metrics
    where(span_name: QUERY_SPAN_NAME)
  end

  def query_metric?
    span_name == QUERY_SPAN_NAME
  end

  def dimension_columns
    Array(dimensions).map { |dim| self.class.sanitize_dimension(dim) }
  end

  def self.sanitize_dimension(dimension)
    dimension.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "").presence || "dim"
  end

  def self.slugify_span_name(span_name)
    span_name.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "").presence || "trace"
  end

  def dimensions
    value = super
    value.nil? ? [] : value
  end

  def filters
    value = super
    value.nil? ? [] : value
  end

  def watermark_ready?
    !backfill_through_timestamp.nil?
  end

  def backfill_finished?
    !backfill_finished_at.nil?
  end

  def after_watermark?(trace)
    return false unless watermark_ready?

    cmp = [
      trace.timestamp.utc,
      trace.trace_id.to_s,
      trace.span_id.to_s
    ] <=> [
      backfill_through_timestamp.utc,
      backfill_through_trace_id.to_s,
      backfill_through_span_id.to_s
    ]
    cmp > 0
  end

  def matches_trace?(trace)
    Array(filters).all? { |filter| filter_matches_trace?(filter, trace) }
  end

  # GreptimeDB has no UPDATE; rewrite mutable fields via INSERT overwrite.
  def update_columns(attributes)
    attributes.each { |key, value| public_send("#{key}=", value) }
    insert_overwrite_row!
    clear_attribute_changes(attributes.keys.map(&:to_s))
    true
  end

  private

  def derive_name
    return if name.present?
    return if query_metric?
    return if span_name.blank? || metric_type.blank?

    self.name = "#{self.class.slugify_span_name(span_name)}_#{metric_type}"
  end

  def normalize_dimensions
    self.dimensions = Array(dimensions).map(&:to_s)
  end

  def normalize_filters
    self.filters = Array(filters).map { |f| f.deep_stringify_keys }
  end

  def ensure_greptime_ts
    self.greptime_ts ||= STABLE_GREPTIME_TS
  end

  def ensure_version
    self.version = 1 if version.nil?
  end

  def name_must_be_unique
    return if name.blank?
    return unless self.class.where(name: name).exists?

    errors.add(:name, :taken)
  end

  def name_matches_convention
    return if query_metric?
    return if span_name.blank? || metric_type.blank? || name.blank?

    expected = "#{self.class.slugify_span_name(span_name)}_#{metric_type}"
    errors.add(:name, "must be #{expected}") unless name == expected
  end

  def name_not_reserved
    return if name.blank?

    errors.add(:name, "is reserved") if RESERVED_TABLE_NAMES.include?(name)
  end

  def dimensions_are_valid
    cols = dimension_columns
    if cols.any? { |c| c !~ NAME_FORMAT }
      errors.add(:dimensions, "contain invalid identifiers")
    end
    errors.add(:dimensions, "must be unique") if cols.uniq.size != cols.size
  end

  def dimensions_only_added
    return unless dimensions_changed?

    previous = Array(dimensions_was)
    current = Array(dimensions)
    return if previous.empty?
    return if previous.all? { |d| current.include?(d) } && current.size >= previous.size

    errors.add(:dimensions, "can only be added, not removed or renamed")
  end

  def create_metric_table!
    TraceToMetrics::TableManager.create!(self)
  end

  def evolve_metric_table!
    previous = Array(dimensions_before_last_save)
    current = Array(dimensions)
    added = current - previous
    return if added.empty?

    TraceToMetrics::TableManager.add_dimensions!(self, added)
    self.version = version.to_i + 1
    insert_overwrite_row!
  end

  # Hook below Persistence#_update_record so Callbacks#_update_record still wraps us.
  def _update_row(_attribute_names, _attempted_action = "update")
    insert_overwrite_row!
    1
  end

  def insert_overwrite_row!
    ensure_greptime_ts
    connection = Greptime::Connection
    table = connection.quote_table_name(self.class.table_name)

    sql = <<~SQL.squish
      INSERT INTO #{table}
        ("name", "span_name", "metric_type", "dimensions", "filters", "bucket_interval",
         "backfill_through_timestamp", "backfill_through_trace_id", "backfill_through_span_id",
         "backfill_finished_at", "version", "greptime_ts")
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    connection.exec_query(
      sql,
      "TraceToMetric InsertOverwrite",
      [
        name,
        span_name,
        metric_type,
        JSON.generate(Array(dimensions)),
        JSON.generate(Array(filters)),
        bucket_interval,
        backfill_through_timestamp,
        backfill_through_trace_id,
        backfill_through_span_id,
        backfill_finished_at,
        version.to_i,
        greptime_ts
      ]
    )
  end

  def filter_matches_trace?(filter, trace)
    column = filter["column"] || filter[:column]
    op = filter["op"] || filter[:op]
    expected = filter.key?("value") ? filter["value"] : filter[:value]
    actual = trace_filter_value(trace, column)

    case op
    when "IS NULL"
      actual.nil? || actual == ""
    when "IS NOT NULL"
      !(actual.nil? || actual == "")
    when "="
      actual.to_s == expected.to_s
    when "<", "<=", ">", ">="
      compare_filter_values?(actual, expected, op)
    else
      false
    end
  end

  def compare_filter_values?(actual, expected, op)
    return false if actual.nil? || actual == ""

    left = Float(actual)
    right = Float(expected)
    case op
    when "<" then left < right
    when "<=" then left <= right
    when ">" then left > right
    when ">=" then left >= right
    end
  rescue ArgumentError, TypeError
    false
  end

  def trace_filter_value(trace, column)
    key = column.to_s
    span_attrs = trace.span_attributes || {}
    return span_attrs[key] if span_attrs.key?(key)
    return span_attrs[key.delete_prefix("span_attributes.")] if key.start_with?("span_attributes.") && span_attrs.key?(key.delete_prefix("span_attributes."))

    resource_attrs = trace.resource_attributes || {}
    return resource_attrs[key] if resource_attrs.key?(key)
    return resource_attrs[key.delete_prefix("resource_attributes.")] if key.start_with?("resource_attributes.") && resource_attrs.key?(key.delete_prefix("resource_attributes."))

    return trace.public_send(key) if trace.respond_to?(key)

    # Greptime stores dotted attribute names as columns; also check flat attributes.
    flat = trace.instance_variable_get(:@flat_attributes)
    return flat[key] if flat.is_a?(Hash) && flat.key?(key)

    nil
  end
end
