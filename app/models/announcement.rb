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

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  has_many :announcement_links, dependent: :destroy

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
  validates :priority,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: PRIORITY_RANGE.begin,
              less_than_or_equal_to: PRIORITY_RANGE.end
            }
  validates :pinned, inclusion: { in: [ true, false ] }
  validate :ends_at_after_starts_at

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
end
