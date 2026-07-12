class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :trackable, :confirmable, :lockable

  has_many :receipts, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :contact_requests, dependent: :nullify
  has_many :passkeys, dependent: :destroy
  has_many :user_sessions, dependent: :destroy
  has_many :user_limit_overrides, dependent: :destroy
  has_many :usage_counters, dependent: :destroy
  has_many :legal_acceptances, dependent: :destroy
  has_one :totp_credential, dependent: :destroy
  has_many :recovery_codes, dependent: :destroy
  has_many :requested_receipt_analysis_runs,
           class_name: "ReceiptAnalysisRun",
           foreign_key: :requested_by_user_id,
           inverse_of: :requested_by_user,
           dependent: :nullify

  has_one_attached :avatar

  validate :avatar_type, if: :avatar_attachment_changed?
  validate :avatar_size, if: :avatar_attachment_changed?

  validates :name, length: { maximum: 30 }, allow_blank: true
  validates :storage_limit_bytes,
            numericality: { only_integer: true, greater_than: 0 }

  THEME_PREFERENCES = %w[system light dark].freeze
  ROUNDING_MODES = %w[floor round ceil].freeze
  ALLOWED_AVATAR_CONTENT_TYPES = %w[
    image/png
    image/jpeg
    image/webp
  ].freeze
  MAX_AVATAR_FILE_SIZE = 5.megabytes
  DEFAULT_GUEST_CLEANUP_RETENTION_DAYS = 7
  GUEST_CLEANUP_RETENTION_PERIOD = DEFAULT_GUEST_CLEANUP_RETENTION_DAYS.days

  attr_accessor :legal_agreement, :legal_agreement_required

  validates :theme_preference,
            inclusion: { in: THEME_PREFERENCES }
  validates :tax_rounding_mode,
            :discount_rounding_mode,
            inclusion: { in: ROUNDING_MODES }

  validate :pending_email_must_be_available, if: -> { pending_email_candidate.present? }
  validate :legal_agreement_must_be_accepted, if: :legal_agreement_required?

  def self.guest_cleanup_retention_period
    SystemSettings.limit_for("retention.guest_users_days").days
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    GUEST_CLEANUP_RETENTION_PERIOD
  end

  def self.avatar_max_file_size
    SystemSettings.limit_for("limits.avatar_image_max_file_size_bytes")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MAX_AVATAR_FILE_SIZE
  end

  scope :guest_cleanup_candidates, ->(cutoff = guest_cleanup_retention_period.ago) {
    where(guest: true)
      .where.not(confirmed_at: nil)
      .where("COALESCE(last_sign_in_at, updated_at) <= ?", cutoff)
  }

  def self.generate_webauthn_id
    WebAuthn.generate_user_id
  end

  def self.guest!
    user = new(
      email: "guest_#{SecureRandom.hex(8)}@example.com",
      password: SecureRandom.urlsafe_base64(12),
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

    self.legal_agreement_required = true
    assign_attributes(attributes.slice(:email, :password, :password_confirmation, :legal_agreement))
    save
  end

  def complete_guest_registration!
    update!(guest: false, session_version: session_version.to_i + 1)
  end

  def display_name
    name.presence || (guest? ? I18n.t("users.display.guest_name") : email.to_s)
  end

  def display_email
    guest? ? I18n.t("users.display.email_unregistered") : email.to_s
  end

  def storage_usage
    Storage.usage_calculator(self)
  end

  def storage_used_bytes
    storage_usage.used_bytes
  end

  def storage_can_add?(byte_size, excluding_blob: nil)
    storage_usage.can_add?(byte_size, excluding_blob: excluding_blob)
  end

  def effective_keep_receipt_images
    return keep_receipt_images unless keep_receipt_images.nil?

    SystemSettings.enabled?("storage.keep_receipt_images_default", user: self)
  end

  def ensure_webauthn_id!
    return webauthn_id if webauthn_id.present?

    with_lock do
      reload
      update!(webauthn_id: self.class.generate_webauthn_id) if webauthn_id.blank?
      webauthn_id
    end
  end

  private

  def legal_agreement_required?
    ActiveModel::Type::Boolean.new.cast(legal_agreement_required)
  end

  def legal_agreement_accepted?
    ActiveModel::Type::Boolean.new.cast(legal_agreement)
  end

  def legal_agreement_must_be_accepted
    return if legal_agreement_accepted?

    errors.add(:legal_agreement, :accepted)
  end

  def pending_email_candidate
    unconfirmed_email.presence || (persisted? && will_save_change_to_email? ? email : nil)
  end

  def pending_email_must_be_available
    normalized_pending_email = pending_email_candidate.to_s.strip.downcase
    pending_relation = self.class.where("LOWER(unconfirmed_email) = ?", normalized_pending_email)
    registered_relation = self.class.where("LOWER(email) = ?", normalized_pending_email)

    if persisted?
      pending_relation = pending_relation.where.not(id: id)
      registered_relation = registered_relation.where.not(id: id)
    end

    return unless pending_relation.exists? || registered_relation.exists?

    add_unique_error(:email, :taken)
  end

  def add_unique_error(attribute, type)
    errors.add(attribute, type) unless errors.added?(attribute, type)
  end

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

    unless avatar.blob.content_type.in?(ALLOWED_AVATAR_CONTENT_TYPES)
      errors.add(:avatar, :invalid_content_type)
      return
    end

    unless Storage.extract_image_dimensions(blob: avatar.blob, attached_change: attachment_changes["avatar"])
      errors.add(:avatar, :invalid_content_type)
    end
  end

  def avatar_attachment_changed?
    attachment_changes.key?("avatar")
  end

  def avatar_size
    return unless avatar.attached?

    max_file_size = self.class.avatar_max_file_size
    if avatar.blob.byte_size > max_file_size
      errors.add(:avatar, :file_too_large, max_size: ActiveSupport::NumberHelper.number_to_human_size(max_file_size))
    end
  end
end
