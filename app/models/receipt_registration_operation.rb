class ReceiptRegistrationOperation < ApplicationRecord
  KINDS = %w[upload batch_upload manual].freeze
  STATES = %w[processing accepted failed].freeze
  MAX_RECEIPTS = 20

  belongs_to :user
  has_many :notifications, as: :notifiable, dependent: :nullify

  validates :operation_key, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :input_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :attempt_key, format: { with: /\A[0-9a-f]{32}\z/ }
  validates :notification_reported, inclusion: { in: [ true, false ] }
  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }
  validates :issued_at, :expires_at, presence: true
  validate :fixed_lifetime
  validate :bounded_acceptance_result

  private

  def fixed_lifetime
    return if issued_at && expires_at && expires_at == issued_at + 24.hours

    errors.add(:expires_at, :invalid)
  end

  def bounded_acceptance_result
    ids = receipt_ids
    valid_ids = ids.is_a?(Array) && ids.size <= MAX_RECEIPTS &&
      ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq == ids
    if state == "accepted"
      valid_ids &&= ids.present? && accepted_at.present?
      valid_ids &&= ids.size == 1 unless kind == "batch_upload"
    else
      valid_ids &&= ids.empty? && accepted_at.nil?
    end
    errors.add(:receipt_ids, :invalid) unless valid_ids
  end
end
