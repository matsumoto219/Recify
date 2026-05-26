class Passkey < ApplicationRecord
  belongs_to :user

  before_validation :normalize_transports

  validates :credential_id, presence: true, uniqueness: true
  validates :public_key, presence: true
  validates :sign_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :transports_must_be_array

  # credential_id and public_key are required WebAuthn credential material.
  # They are persisted here, but must never be copied into AuditLog metadata.

  private

  def normalize_transports
    self.transports =
      case transports
      when nil
        []
      when Array
        transports.compact.map(&:to_s).reject(&:blank?).uniq
      else
        [ transports.to_s ].reject(&:blank?)
      end
  end

  def transports_must_be_array
    return if transports.is_a?(Array)

    errors.add(:transports, :invalid)
  end
end
