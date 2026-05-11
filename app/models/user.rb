class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :receipts, dependent: :destroy

  has_one_attached :avatar

  validate :avatar_type
  validate :avatar_size

  validates :name, length: { maximum: 30 }, allow_blank: true

  THEME_PREFERENCES = %w[system light dark].freeze

  validates :theme_preference,
            inclusion: { in: THEME_PREFERENCES }

  def self.guest!
    create!(
      email: "guest_#{SecureRandom.hex(8)}@example.com",
      password: SecureRandom.urlsafe_base64(12),
      name: "ゲストユーザー",
      guest: true
    )
  end
  private

  def avatar_type
    return unless avatar.attached?

    unless avatar.content_type.in?([ "image/png", "image/jpeg", "image/webp" ])
      errors.add(:avatar, "はPNG/JPEG/WebP形式でアップロードしてください")
    end
  end

  def avatar_size
    return unless avatar.attached?

    if avatar.blob.byte_size > 5.megabytes
      errors.add(:avatar, "は5MB以下にしてください")
    end
  end
end
