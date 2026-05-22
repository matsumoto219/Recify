class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :trackable, :confirmable, :lockable

  has_many :receipts, dependent: :destroy
  has_many :notifications, dependent: :destroy

  has_one_attached :avatar

  validate :avatar_type
  validate :avatar_size

  validates :name, length: { maximum: 30 }, allow_blank: true
  validates :storage_limit_bytes,
            numericality: { only_integer: true, greater_than: 0 }

  THEME_PREFERENCES = %w[system light dark].freeze
  GUEST_CLEANUP_RETENTION_PERIOD = 7.days

  validates :theme_preference,
            inclusion: { in: THEME_PREFERENCES }

  scope :guest_cleanup_candidates, ->(cutoff = GUEST_CLEANUP_RETENTION_PERIOD.ago) {
    where(guest: true)
      .where.not(confirmed_at: nil)
      .where("COALESCE(last_sign_in_at, updated_at) <= ?", cutoff)
  }

  def self.guest!
    user = new(
      email: "guest_#{SecureRandom.hex(8)}@example.com",
      password: SecureRandom.urlsafe_base64(12),
      name: "GUEST USER",
      guest: true
    )

    user.skip_confirmation!
    user.save!
    user
  end

  def confirm(args = {})
    completing_guest_registration = guest_registration_pending?
    confirmed = super
    complete_guest_registration! if confirmed && completing_guest_registration

    confirmed
  end

  def guest_registration_pending?
    guest? && pending_reconfirmation?
  end

  def start_guest_registration(attributes)
    return false unless guest?

    update(attributes.slice(:email, :password, :password_confirmation))
  end

  def complete_guest_registration!
    update!(guest: false)
  end

  def display_name
    name.presence || (guest? ? I18n.t("users.display.guest_name") : email.to_s)
  end

  def display_email
    guest? ? I18n.t("users.display.email_unregistered") : email.to_s
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

  def send_devise_notification(notification, *args)
    return if suppress_guest_fake_email_notification?(notification)

    super
  end

  def send_email_changed_notification?
    return false if guest?

    super
  end

  def suppress_guest_fake_email_notification?(notification)
    return false unless guest?
    return false if notification == :confirmation_instructions && pending_reconfirmation?

    true
  end

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
