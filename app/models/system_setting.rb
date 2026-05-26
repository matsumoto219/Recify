class SystemSetting < ApplicationRecord
  belongs_to :updated_by_user,
             class_name: "User",
             optional: true

  validates :key, presence: true, uniqueness: true
  validate :key_must_be_defined
  validate :value_must_be_hash
  validate :value_must_match_definition

  private

  def key_must_be_defined
    return if key.blank?
    return if SystemSettings.valid_key?(key)

    errors.add(:key, :inclusion)
  end

  def value_must_be_hash
    errors.add(:value, :invalid) unless value.is_a?(Hash)
  end

  def value_must_match_definition
    return if key.blank? || !SystemSettings.valid_key?(key) || !value.is_a?(Hash)

    SystemSettings.validate_stored_value!(key, value)
  rescue SystemSettings::ValidationError => e
    errors.add(:value, e.message)
  end
end
