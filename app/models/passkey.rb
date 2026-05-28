class Passkey < ApplicationRecord
  UID_PREFIX = "psk_"
  UID_RANDOM_LENGTH = 16
  UID_FORMAT = /\A#{UID_PREFIX}[A-Za-z0-9]{#{UID_RANDOM_LENGTH}}\z/
  UID_RETRY_LIMIT = 10
  UID_UNIQUE_INDEX_NAME = "index_passkeys_on_uid"

  belongs_to :user

  before_validation :assign_uid, on: :create
  before_validation :normalize_transports

  validates :uid,
            presence: true,
            uniqueness: true,
            length: { maximum: 32 },
            format: { with: UID_FORMAT }
  validates :credential_id, presence: true, uniqueness: true
  validates :public_key, presence: true
  validates :sign_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :transports_must_be_array

  # credential_id and public_key are required WebAuthn credential material.
  # They are persisted here, but must never be copied into AuditLog metadata.

  def save(*args, **kwargs, &block)
    save_with_uid_retry { super(*args, **kwargs, &block) }
  end

  def save!(*args, **kwargs, &block)
    save_with_uid_retry { super(*args, **kwargs, &block) }
  end

  def to_param
    uid
  end

  private

  def assign_uid
    self.uid ||= generate_unique_uid
  end

  def generate_unique_uid
    UID_RETRY_LIMIT.times do
      candidate = "#{UID_PREFIX}#{SecureRandom.base58(UID_RANDOM_LENGTH)}"
      return candidate unless self.class.unscoped.exists?(uid: candidate)
    end

    raise ActiveRecord::RecordNotUnique, "Could not generate unique passkey uid"
  end

  def save_with_uid_retry
    retry_count = 0

    begin
      yield
    rescue ActiveRecord::RecordNotUnique => e
      raise unless new_record? && uid_collision_error?(e)

      retry_count += 1
      raise if retry_count > UID_RETRY_LIMIT

      self.uid = generate_unique_uid
      retry
    end
  end

  def uid_collision_error?(error)
    error.message.to_s.include?(UID_UNIQUE_INDEX_NAME)
  end

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
