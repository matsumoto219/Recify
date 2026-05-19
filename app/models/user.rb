class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :receipts, dependent: :destroy
  has_many :notifications, dependent: :destroy

  has_one_attached :avatar

  validate :avatar_type
  validate :avatar_size

  validates :name, length: { maximum: 30 }, allow_blank: true
  validates :storage_limit_bytes,
            numericality: { only_integer: true, greater_than: 0 }

  THEME_PREFERENCES = %w[system light dark].freeze

  validates :theme_preference,
            inclusion: { in: THEME_PREFERENCES }

  def self.guest!
    create!(
      email: "guest_#{SecureRandom.hex(8)}@example.com",
      password: SecureRandom.urlsafe_base64(12),
      name: "GUEST USER",
      guest: true
    )
  end

  def storage_usage
    Storage::UsageCalculator.new(self)
  end

  def storage_used_bytes
    storage_usage.used_bytes
  end

  def storage_can_add?(byte_size, excluding_blob: nil)
    storage_usage.can_add?(byte_size, excluding_blob: excluding_blob)
  end

  private

  def avatar_type
    return unless avatar.attached?

    unless avatar.content_type.in?([ "image/png", "image/jpeg", "image/webp" ])
      errors.add(:avatar, :invalid_content_type)
    end
  end

  def avatar_size
    return unless avatar.attached?

    if avatar.blob.byte_size > 5.megabytes
      errors.add(:avatar, :file_too_large)
    end
  end
end
