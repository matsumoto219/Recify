# frozen_string_literal: true

class SecurityIpBlock < ApplicationRecord
  STATUSES = %w[active revoked].freeze

  belongs_to :created_by,
             class_name: "User"
  belongs_to :revoked_by,
             class_name: "User",
             optional: true
  belongs_to :source_security_event,
             class_name: "SecurityEvent",
             optional: true

  before_validation :normalize_ip_address
  before_validation :normalize_status
  before_validation :apply_default_metadata

  validates :ip_address, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :reason, presence: true
  validate :metadata_is_hash
  validate :ip_address_is_blockable
  validate :revocation_fields_are_consistent

  scope :active_status, -> { where(status: "active") }
  scope :currently_effective, -> { active_status.where("expires_at IS NULL OR expires_at > ?", Time.current) }

  class << self
    def currently_effective_for_ip(ip_address)
      normalized = Security::IpAddress.normalize(ip_address)
      return none if normalized.blank?

      currently_effective.where(ip_address: normalized)
    end

    def active_status_for_ip(ip_address)
      normalized = Security::IpAddress.normalize(ip_address)
      return none if normalized.blank?

      active_status.where(ip_address: normalized)
    end
  end

  def active?
    status == "active"
  end

  def revoked?
    status == "revoked"
  end

  def currently_effective?
    active? && (expires_at.blank? || expires_at.future?)
  end

  private

  def normalize_ip_address
    normalized = Security::IpAddress.normalize(ip_address)
    self.ip_address = normalized if normalized.present?
  end

  def normalize_status
    self.status = status.to_s.strip.presence || "active"
  end

  def apply_default_metadata
    self.metadata = {} unless metadata.is_a?(Hash)
  end

  def metadata_is_hash
    errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
  end

  def ip_address_is_blockable
    normalized = Security::IpAddress.normalize(ip_address)
    if normalized.blank?
      errors.add(:ip_address, :invalid)
      return
    end

    return if Security::IpAddress.blockable?(normalized)

    errors.add(:ip_address, Security::IpAddress.non_blockable_reason(normalized) || :invalid)
  end

  def revocation_fields_are_consistent
    return unless revoked?

    errors.add(:revoked_at, :blank) if revoked_at.blank?
    errors.add(:revoked_by, :blank) if revoked_by.blank?
    errors.add(:revoked_reason, :blank) if revoked_reason.blank?
  end
end
