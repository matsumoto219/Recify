# frozen_string_literal: true

module Security
  class ManualIpUnblocker
    Result = Struct.new(:success, :block, :ip_address, :error_code, keyword_init: true) do
      def success?
        success == true
      end

      def failure?
        !success?
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(ip_address:, reason:, revoked_by:, source_security_event: nil)
      @ip_address = IpAddress.normalize(ip_address)
      @reason = reason.to_s.strip
      @revoked_by = revoked_by
      @source_security_event = source_security_event
    end

    def call
      validate!

      block.update!(
        status: "revoked",
        revoked_at: Time.current,
        revoked_by: revoked_by,
        revoked_reason: reason
      )
      IpAccessRules.clear_cache!(ip_address)

      Result.new(success: true, block: block, ip_address: ip_address)
    rescue Security::ValidationError => e
      Result.new(success: false, ip_address: ip_address, error_code: e.message)
    rescue ActiveRecord::RecordInvalid
      Result.new(success: false, ip_address: ip_address, error_code: "manual_ip_unblock_failed")
    end

    private

    attr_reader :ip_address, :reason, :revoked_by, :source_security_event

    def validate!
      raise ValidationError, "invalid_ip" if ip_address.blank?
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "actor_required" unless revoked_by
      raise ValidationError, "source_security_event_ip_mismatch" if source_security_event_ip_mismatch?
      raise ValidationError, "no_active_manual_block" if block.blank?
    end

    def block
      @block ||= SecurityIpBlock.currently_effective_for_ip(ip_address).order(created_at: :desc).first
    end

    def source_security_event_ip_mismatch?
      return false if source_security_event.blank?

      source_ip = IpAddress.normalize(source_security_event.ip_address)
      source_ip.present? && source_ip != ip_address
    end
  end
end
