# frozen_string_literal: true

module Security
  class ManualIpBlocker
    DEFAULT_EXPIRES_IN = 24.hours
    PERMANENT_CONFIRMATION = "BLOCK IP PERMANENTLY"

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

    def initialize(
      ip_address:,
      reason:,
      created_by:,
      expires_at: nil,
      source_security_event: nil,
      metadata: {},
      permanent: false,
      permanent_confirmation: nil
    )
      @ip_address = IpAddress.normalize(ip_address)
      @reason = reason.to_s.strip
      @created_by = created_by
      @expires_at = expires_at
      @source_security_event = source_security_event
      @metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}
      @permanent = permanent == true
      @permanent_confirmation = permanent_confirmation.to_s.strip
    end

    def call
      block = IpAccessOperationLock.call(ip_address: ip_address) do
        validate!
        SecurityIpBlock.create!(
          ip_address: ip_address,
          status: "active",
          reason: reason,
          expires_at: resolved_expires_at,
          created_by: created_by,
          source_security_event: source_security_event,
          metadata: metadata
        )
      end

      Result.new(success: true, block: block, ip_address: ip_address)
    rescue Security::ValidationError => e
      Result.new(success: false, ip_address: ip_address, error_code: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, ip_address: ip_address, error_code: record_error_code(e.record))
    end

    private

    attr_reader :ip_address, :reason, :created_by, :expires_at, :source_security_event,
                :metadata, :permanent, :permanent_confirmation

    def validate!
      raise ValidationError, "invalid_ip" if ip_address.blank?
      raise ValidationError, IpAddress.non_blockable_reason(ip_address) unless IpAddress.blockable?(ip_address)
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "actor_required" unless created_by
      raise ValidationError, "source_security_event_ip_mismatch" if source_security_event_ip_mismatch?
      raise ValidationError, "permanent_confirmation_required" if permanent && permanent_confirmation != PERMANENT_CONFIRMATION
      raise ValidationError, "expires_at_in_past" if resolved_expires_at.present? && !resolved_expires_at.future?
      raise ValidationError, "already_blocked" if SecurityIpBlock.currently_effective_for_ip(ip_address).exists?
    end

    def resolved_expires_at
      return @resolved_expires_at if defined?(@resolved_expires_at)

      @resolved_expires_at =
        if permanent
          nil
        elsif expires_at.blank?
          DEFAULT_EXPIRES_IN.from_now
        elsif expires_at.respond_to?(:future?)
          expires_at
        else
          Time.zone.parse(expires_at.to_s)
        end
    rescue ArgumentError, TypeError
      raise ValidationError, "expires_at_invalid"
    end

    def source_security_event_ip_mismatch?
      return false if source_security_event.blank?

      source_ip = IpAddress.normalize(source_security_event.ip_address)
      source_ip.present? && source_ip != ip_address
    end

    def record_error_code(record)
      return "invalid_ip" if record.errors.added?(:ip_address, :invalid)
      return record.errors.details[:ip_address].first[:error].to_s if record.errors.details[:ip_address].present?

      "manual_ip_block_failed"
    end
  end
end
