class SpanToMetric < ApplicationRecord
  METRIC_TYPES = %w[counter].freeze
  NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/
  RESERVED_TABLE_NAMES = %w[
    spans
    span_to_metrics
    schema_migrations
    ar_internal_metadata
    solid_queue_jobs
    solid_cache_entries
    solid_cable_messages
  ].freeze

  before_validation :derive_name, on: :create
  before_validation :normalize_dimensions

  validates :span_name, presence: true
  validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validate :name_matches_convention
  validate :name_not_reserved
  validate :dimensions_are_valid
  validate :dimensions_only_added, on: :update

  after_create :create_metric_table!
  after_update :evolve_metric_table!, if: :saved_change_to_dimensions?

  def self.for_span_name(span_name)
    find_by(span_name: span_name)
  end

  def dimension_columns
    Array(dimensions).map { |dim| self.class.sanitize_dimension(dim) }
  end

  def self.sanitize_dimension(dimension)
    dimension.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "").presence || "dim"
  end

  def self.slugify_span_name(span_name)
    span_name.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "").presence || "span"
  end

  private

  def derive_name
    return if name.present?
    return if span_name.blank? || metric_type.blank?

    self.name = "#{self.class.slugify_span_name(span_name)}_#{metric_type}"
  end

  def normalize_dimensions
    self.dimensions = Array(dimensions).map(&:to_s)
  end

  def name_matches_convention
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
    SpanToMetrics::TableManager.create!(self)
  end

  def evolve_metric_table!
    previous = Array(dimensions_before_last_save)
    current = Array(dimensions)
    added = current - previous
    return if added.empty?

    SpanToMetrics::TableManager.add_dimensions!(self, added)
    update_column(:version, version + 1)
  end
end
