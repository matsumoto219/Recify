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
  LONG_RETENTION_RECEIPT_STATUSES = %w[review_needed failed].freeze

  SHORT_RETENTION_DAYS = 14
  DEFAULT_RETENTION_DAYS = 30
  LONG_RETENTION_DAYS = 90
  SHORT_RETENTION_PERIOD = SHORT_RETENTION_DAYS.days
  DEFAULT_RETENTION_PERIOD = DEFAULT_RETENTION_DAYS.days
  LONG_RETENTION_PERIOD = LONG_RETENTION_DAYS.days

  # Store only bounded, sanitized summaries/snapshots here. Do not persist Azure
  # raw response bodies, headers, Operation-Location URLs, endpoints, API keys,
  # full prompts, full AI responses, or image payloads. OCR snapshots may include
  # normalized text such as lines and item raw_text for AI/finalize retry and
  # admin investigation, capped by SnapshotBuilder limits.
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

  has_one_attached :ocr_response_artifact

  before_validation :assign_run_key, on: :create
  before_validation :assign_default_expires_at, on: :create
  after_create_commit :broadcast_receipt_processing_phase_update, if: :broadcast_receipt_processing_phase_update?
  after_update_commit :broadcast_receipt_processing_phase_update, if: :broadcast_receipt_processing_phase_update?

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

  def self.default_expires_at_for(status:, source:, receipt_status: nil, from: Time.current)
    from + retention_period_for(status:, source:, receipt_status:)
  end

  def self.retention_period_for(status:, source:, receipt_status: nil)
    normalized_status = status.to_s
    normalized_source = source.to_s
    normalized_receipt_status = receipt_status.to_s

    return long_retention_period if LONG_RETENTION_SOURCES.include?(normalized_source)
    return long_retention_period if LONG_RETENTION_STATUSES.include?(normalized_status)
    return long_retention_period if LONG_RETENTION_RECEIPT_STATUSES.include?(normalized_receipt_status)
    return short_retention_period if SHORT_RETENTION_STATUSES.include?(normalized_status)

    default_retention_period
  end

  def self.short_retention_period
    retention_days_for("retention.analysis_runs_short_days", SHORT_RETENTION_DAYS).days
  end

  def self.default_retention_period
    retention_days_for("retention.analysis_runs_default_days", DEFAULT_RETENTION_DAYS).days
  end

  def self.long_retention_period
    retention_days_for("retention.analysis_runs_failed_days", LONG_RETENTION_DAYS).days
  end

  def self.retention_days_for(key, default_days)
    SystemSettings.limit_for(key)
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    default_days
  end

  def active?
    ACTIVE_STATUSES.include?(status.to_s)
  end

  private

  def broadcast_receipt_processing_phase_update?
    return false unless receipt&.processing?
    return false unless active?
    return true if previously_new_record?

    saved_change_to_stage? ||
      saved_change_to_status? ||
      saved_change_to_ocr_started_at? ||
      saved_change_to_ocr_finished_at? ||
      saved_change_to_ai_started_at? ||
      saved_change_to_ai_finished_at? ||
      saved_change_to_finalized_at?
  end

  def broadcast_receipt_processing_phase_update
    return unless receipt&.user

    receipt.broadcast_replace_later_to(
      [ receipt.user, :receipts ],
      target: receipt.dom_target_id,
      partial: "shared/receipts/receipt_card",
      locals: { receipt: receipt, analysis_run: self }
    )
  end

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
