# frozen_string_literal: true

class SecurityIpAction < ApplicationRecord
  ACTION_TYPES = %w[
    rate_limit_triggered
    scanner_restriction
    admin_probe_restriction
    direct_upload_probe_restriction
    manual_ip_block
    manual_ip_unblock
    rack_attack_ban_reset
  ].freeze

  SOURCES = %w[rack_attack manual_admin].freeze
  STATUSES = %w[observed active revoked reset].freeze
  REASON_MAX_BYTES = 1_000

  belongs_to :source_security_event,
             class_name: "SecurityEvent",
             optional: true
  belongs_to :security_ip_block,
             optional: true
  belongs_to :actor_user,
             class_name: "User",
             optional: true

  before_validation :normalize_ip_address
  before_validation :normalize_strings
  before_validation :apply_defaults
  before_validation :sanitize_metadata

  validates :ip_address, presence: true
  validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :first_seen_at, presence: true
  validates :last_seen_at, presence: true
  validates :matched_rule, length: { maximum: 255 }, allow_blank: true
  validates :reason, length: { maximum: REASON_MAX_BYTES }, allow_blank: true
  validate :metadata_is_hash

  scope :recent_first, -> { order(last_seen_at: :desc, id: :desc) }

  def display_status(now: Time.current)
    return "expired" if status == "active" && expires_at.present? && expires_at <= now

    status
  end

  private

  def normalize_ip_address
    normalized = Security::IpAddress.normalize(ip_address)
    self.ip_address = normalized if normalized.present?
  end

  def normalize_strings
    self.action_type = action_type.to_s.strip
    self.source = source.to_s.strip
    self.status = status.to_s.strip.presence || "observed"
    self.matched_rule = truncate_string(matched_rule.to_s.presence, 255)
    self.reason = sanitized_reason
  end

  def apply_defaults
    now = Time.current
    self.count ||= 1
    self.first_seen_at ||= now
    self.last_seen_at ||= first_seen_at || now
    self.metadata = {} unless metadata.is_a?(Hash)
  end

  def sanitize_metadata
    return unless metadata.is_a?(Hash)

    self.metadata = SecurityEvents.sanitize_metadata(metadata)
  end

  def metadata_is_hash
    errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
  end

  def truncate_string(value, max_length)
    return if value.blank?

    value.to_s.first(max_length)
  end

  def sanitized_reason
    value = reason.to_s.presence
    return if value.blank?

    truncate_bytes(SecurityEvents.sanitize_text(value), REASON_MAX_BYTES)
  end

  def truncate_bytes(value, max_bytes)
    return value if value.bytesize <= max_bytes

    value.byteslice(0, max_bytes).scrub
  end
end
