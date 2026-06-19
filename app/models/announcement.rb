class Announcement < ApplicationRecord
  PUBLIC_ID_PREFIX = "ann_"
  PUBLIC_ID_RANDOM_LENGTH = 16
  PUBLIC_ID_FORMAT = /\A#{PUBLIC_ID_PREFIX}[A-Za-z0-9]{#{PUBLIC_ID_RANDOM_LENGTH}}\z/
  PUBLIC_ID_RETRY_LIMIT = 10
  PUBLIC_ID_UNIQUE_INDEX_NAME = "index_announcements_on_public_id"

  STATUSES = %w[
    draft
    published
    archived
  ].freeze

  KINDS = %w[
    general
    release
    maintenance
    incident
  ].freeze

  PRIORITY_RANGE = -100..100
  ALLOWED_IMAGE_CONTENT_TYPES = %w[
    image/jpeg
    image/png
    image/webp
  ].freeze
  MAX_IMAGE_FILE_SIZE = 2.megabytes
  MIN_IMAGE_DIMENSION = 100
  MAX_IMAGE_DIMENSION = 4096

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  has_many :announcement_links, dependent: :destroy
  has_one_attached :image
  accepts_nested_attributes_for :announcement_links,
                                allow_destroy: true,
                                reject_if: :blank_announcement_link_attributes?

  before_validation :assign_public_id, on: :create

  validates :public_id,
            presence: true,
            uniqueness: true,
            length: { maximum: 32 },
            format: { with: PUBLIC_ID_FORMAT }
  validates :title, presence: true, length: { maximum: 120 }
  validates :body, presence: true, length: { maximum: 2000 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :image_alt_text, presence: true, if: -> { image.attached? }
  validates :image_alt_text, length: { maximum: 160 }, allow_blank: true
  validates :priority,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: PRIORITY_RANGE.begin,
              less_than_or_equal_to: PRIORITY_RANGE.end
            }
  validates :pinned, inclusion: { in: [ true, false ] }
  validate :ends_at_after_starts_at
  validate :validate_image_content_type
  validate :validate_image_file_size
  validate :validate_image_dimensions

  scope :draft, -> { where(status: "draft") }
  scope :published, -> { where(status: "published") }
  scope :archived, -> { where(status: "archived") }
  scope :current, lambda { |at = Time.current|
    published.where("(starts_at IS NULL OR starts_at <= ?) AND (ends_at IS NULL OR ends_at > ?)", at, at)
  }
  scope :scheduled, ->(at = Time.current) { published.where("starts_at > ?", at) }
  scope :expired, ->(at = Time.current) { published.where("ends_at <= ?", at) }
  scope :visible_on_public, ->(at = Time.current) { current(at) }
  scope :ordered_for_public, lambda {
    order(pinned: :desc, priority: :desc)
      .order(Arel.sql("published_at DESC NULLS LAST"))
      .order(created_at: :desc)
  }
  scope :ordered_for_admin, -> { order(created_at: :desc) }

  def save(*args, **kwargs, &block)
    save_with_public_id_retry { super(*args, **kwargs, &block) }
  end

  def save!(*args, **kwargs, &block)
    save_with_public_id_retry { super(*args, **kwargs, &block) }
  end

  def to_param
    public_id
  end

  def self.image_max_file_size
    SystemSettings.limit_for("limits.announcement_image_max_file_size_bytes")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MAX_IMAGE_FILE_SIZE
  end

  def self.image_min_dimension
    SystemSettings.limit_for("limits.announcement_image_min_dimension_px")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MIN_IMAGE_DIMENSION
  end

  def self.image_max_dimension
    SystemSettings.limit_for("limits.announcement_image_max_dimension_px")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MAX_IMAGE_DIMENSION
  end

  private

  def assign_public_id
    self.public_id ||= generate_unique_public_id
  end

  def generate_unique_public_id
    PUBLIC_ID_RETRY_LIMIT.times do
      candidate = "#{PUBLIC_ID_PREFIX}#{SecureRandom.base58(PUBLIC_ID_RANDOM_LENGTH)}"
      return candidate unless self.class.unscoped.exists?(public_id: candidate)
    end

    raise ActiveRecord::RecordNotUnique, "Could not generate unique announcement public_id"
  end

  def save_with_public_id_retry
    retry_count = 0

    begin
      yield
    rescue ActiveRecord::RecordNotUnique => e
      raise unless new_record? && public_id_collision_error?(e)

      retry_count += 1
      raise if retry_count > PUBLIC_ID_RETRY_LIMIT

      self.public_id = generate_unique_public_id
      retry
    end
  end

  def public_id_collision_error?(error)
    error.message.to_s.include?(PUBLIC_ID_UNIQUE_INDEX_NAME)
  end

  def ends_at_after_starts_at
    return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

    errors.add(:ends_at, :after_starts_at)
  end

  def validate_image_content_type
    return unless image.attached?
    return if ALLOWED_IMAGE_CONTENT_TYPES.include?(image.blob.content_type)

    errors.add(:image, :invalid_content_type)
  end

  def validate_image_file_size
    return unless image.attached?
    max_file_size = self.class.image_max_file_size
    return if image.blob.byte_size <= max_file_size

    errors.add(:image, :file_too_large, max_size: ActiveSupport::NumberHelper.number_to_human_size(max_file_size))
  end

  def validate_image_dimensions
    return unless image.attached?
    return unless ALLOWED_IMAGE_CONTENT_TYPES.include?(image.blob.content_type)

    dimensions = Storage.extract_image_dimensions(blob: image.blob, attached_change: attachment_changes["image"])
    unless dimensions
      errors.add(:image, :invalid_content_type)
      return
    end

    width = dimensions.fetch(:width)
    height = dimensions.fetch(:height)

    min_dimension = self.class.image_min_dimension
    max_dimension = self.class.image_max_dimension

    if width < min_dimension || height < min_dimension
      errors.add(:image, :image_too_small, min_dimension: min_dimension)
      return
    end

    return if width <= max_dimension && height <= max_dimension

    errors.add(:image, :image_too_large, max_dimension: max_dimension)
  end

  def blank_announcement_link_attributes?(attributes)
    attributes["id"].blank? &&
      attributes["label"].blank? &&
      attributes["url"].blank?
  end
end
