class ReceiptAnalysisRun < ApplicationRecord
  STAGES = %w[
    queued
    ocr
    ocr_validation
    ai
    finalize
    completed
  ].freeze

  STATUSES = %w[
    queued
    running
    succeeded
    failed
    skipped
    superseded
    canceled
  ].freeze

  SOURCES = %w[
    upload
    batch_upload
    admin_retry
    system_retry
  ].freeze

  ACTIVE_STATUSES = %w[queued running].freeze
  SHORT_RETENTION_STATUSES = %w[skipped superseded canceled].freeze
  LONG_RETENTION_STATUSES = %w[failed].freeze
  LONG_RETENTION_SOURCES = %w[admin_retry].freeze

  DEFAULT_RETENTION_PERIOD = 30.days
  SHORT_RETENTION_PERIOD = 14.days
  LONG_RETENTION_PERIOD = 90.days

  # Store only small, sanitized summaries here. Do not persist OCR raw text,
  # Azure raw responses, full prompts, full AI responses, or image payloads.
  belongs_to :receipt, inverse_of: :receipt_analysis_runs
  belongs_to :requested_by_user,
             class_name: "User",
             optional: true,
             inverse_of: :requested_receipt_analysis_runs
  belongs_to :parent_run,
             class_name: "ReceiptAnalysisRun",
             optional: true,
             inverse_of: :child_runs

  has_many :child_runs,
           class_name: "ReceiptAnalysisRun",
           foreign_key: :parent_run_id,
           inverse_of: :parent_run,
           dependent: :nullify

  before_validation :assign_run_key, on: :create
  before_validation :assign_default_expires_at, on: :create

  validates :run_key, presence: true, uniqueness: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :stage, presence: true, inclusion: { in: STAGES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :attempt_number,
            numericality: { only_integer: true, greater_than: 0 }
  validates :ocr_latency_ms,
            :ai_latency_ms,
            :total_latency_ms,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  validate :active_run_must_be_unique_per_receipt, if: :active?

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :expired, ->(time = Time.current) { where(expires_at: ..time) }

  def self.default_expires_at_for(status:, source:, from: Time.current)
    from + retention_period_for(status:, source:)
  end

  def self.retention_period_for(status:, source:)
    normalized_status = status.to_s
    normalized_source = source.to_s

    return LONG_RETENTION_PERIOD if LONG_RETENTION_SOURCES.include?(normalized_source)
    return LONG_RETENTION_PERIOD if LONG_RETENTION_STATUSES.include?(normalized_status)
    return SHORT_RETENTION_PERIOD if SHORT_RETENTION_STATUSES.include?(normalized_status)

    DEFAULT_RETENTION_PERIOD
  end

  def active?
    ACTIVE_STATUSES.include?(status.to_s)
  end

  private

  def assign_run_key
    self.run_key ||= SecureRandom.uuid
  end

  def assign_default_expires_at
    self.expires_at ||= self.class.default_expires_at_for(status: status, source: source)
  end

  def active_run_must_be_unique_per_receipt
    return if receipt_id.blank?

    relation = self.class.active.where(receipt_id: receipt_id)
    relation = relation.where.not(id: id) if persisted?

    errors.add(:receipt, :taken) if relation.exists?
  end
end
