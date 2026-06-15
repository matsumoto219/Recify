class UserLimitOverride < ApplicationRecord
  belongs_to :user
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :updated_by_user, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: { scope: :user_id }
  validates :value, presence: true
  validate :key_must_be_allowlisted
  validate :value_must_be_valid_for_key

  before_validation :normalize_key
  before_validation :normalize_value

  scope :active, -> {
    where(enabled: true)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def integer_value
    UserLimits.cast_value(key, value)
  end

  private

  def normalize_key
    self.key = key.to_s.strip
  end

  def normalize_value
    raw_value =
      if value.is_a?(Hash)
        value["value"] || value[:value]
      else
        value
      end

    self.value = { "value" => raw_value } if raw_value.present?
  end

  def key_must_be_allowlisted
    return if UserLimits.valid_key?(key)

    errors.add(:key, :inclusion)
  end

  def value_must_be_valid_for_key
    return if key.blank? || value.blank?

    UserLimits.cast_value(key, value)
  rescue UserLimits::ValidationError => error
    errors.add(:value, error.message)
  end
end
