# frozen_string_literal: true

module SystemOperations
  class IpAccessOperationExecutor
    OPERATIONS = {
      "manual_ip_block" => {
        action: "admin.ip_access.manual_block",
        confirmation: "BLOCK IP"
      },
      "manual_ip_unblock" => {
        action: "admin.ip_access.manual_unblock",
        confirmation: "UNBLOCK IP"
      },
      "rack_attack_ip_ban_reset" => {
        action: "admin.ip_access.rack_attack_ban_reset",
        confirmation: "RESET IP BAN"
      }
    }.freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      operation:,
      ip_address:,
      actor:,
      reason:,
      request:,
      reauthentication:,
      confirmation:,
      source_security_event: nil,
      expires_at: nil,
      rack_attack_target: nil
    )
      @operation = operation.to_s
      @raw_ip_address = ip_address
      @ip_address = Security::IpAddress.normalize(ip_address)
      @actor = actor
      @reason = reason.to_s.strip
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
      @confirmation = confirmation.to_s.strip
      @source_security_event = source_security_event
      @expires_at = expires_at
      @rack_attack_target = rack_attack_target.to_s.presence || Security::RackAttackBanResetter::DEFAULT_TARGET
    end

    def call
      validate!

      before_state = current_state
      ip_access_result = execute_operation!
      raise ValidationError, ip_access_result.error_code if ip_access_result.respond_to?(:failure?) && ip_access_result.failure?

      after_state = current_state
      audit_log = record_success_audit!(
        result: ip_access_result,
        before_state: before_state,
        after_state: after_state
      )

      Result.new(
        success: true,
        operation: operation,
        ip_access_result: ip_access_result,
        security_ip_block: security_ip_block_from(ip_access_result),
        before_state: before_state,
        after_state: after_state,
        audit_log: audit_log
      )
    rescue StandardError => e
      audit_log = record_failed_audit!(e)

      Result.new(
        success: false,
        operation: operation,
        ip_access_result: nil,
        security_ip_block: nil,
        before_state: safe_current_state,
        after_state: {},
        audit_log: audit_log,
        error_code: error_code_for(e),
        error_message: e.message
      )
    end

    private

    attr_reader :operation, :raw_ip_address, :ip_address, :actor, :reason, :request,
                :reauthentication, :confirmation, :source_security_event, :expires_at,
                :rack_attack_target

    def validate!
      raise ValidationError, "unknown_operation" unless operation_config
      raise ValidationError, "invalid_ip" if ip_address.blank?
      raise ValidationError, "actor_required" unless actor
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "reauthentication_required" unless fresh_passkey_reauthentication?
      raise ValidationError, "confirmation_required" unless confirmation_valid?
      raise ValidationError, "source_security_event_ip_mismatch" if source_security_event_ip_mismatch?
      raise ValidationError, "current_ip_block_forbidden" if current_admin_ip_block_forbidden?
    end

    def execute_operation!
      case operation
      when "manual_ip_block"
        Security.manual_ip_block(
          ip_address: ip_address,
          reason: reason,
          created_by: actor,
          expires_at: parsed_expires_at,
          source_security_event: source_security_event,
          metadata: operation_metadata
        )
      when "manual_ip_unblock"
        Security.manual_ip_unblock(
          ip_address: ip_address,
          reason: reason,
          revoked_by: actor,
          source_security_event: source_security_event
        )
      when "rack_attack_ip_ban_reset"
        Security.rack_attack_ban_reset(
          ip_address: ip_address,
          target: rack_attack_target
        )
      end
    end

    def record_success_audit!(result:, before_state:, after_state:)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: operation_config.fetch(:action),
        target: security_ip_block_from(result),
        target_uid: target_uid,
        reason: reason,
        outcome: "succeeded",
        metadata: audit_metadata(result),
        before_state: before_state,
        after_state: after_state,
        request: request
      )
    end

    def record_failed_audit!(error)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: operation_config&.fetch(:action) || "admin.ip_access.unknown_operation",
        target_uid: target_uid,
        reason: reason.presence,
        outcome: "failed",
        error_code: error_code_for(error),
        metadata: failure_audit_metadata(error),
        before_state: safe_current_state,
        after_state: {},
        request: request
      )
    end

    def current_state
      Security.ip_access_snapshot(ip_address: ip_address)
    end

    def safe_current_state
      return {} if raw_ip_address.blank?

      Security.ip_access_snapshot(ip_address: raw_ip_address)
    rescue StandardError
      {}
    end

    def audit_metadata(result)
      base_audit_metadata.merge(
        rack_attack_target: rack_attack_target,
        reset_targets: result.respond_to?(:reset_targets) ? result.reset_targets : nil,
        expires_at: parsed_expires_at&.iso8601,
        source_security_event_id: source_security_event&.id
      ).compact
    end

    def failure_audit_metadata(error)
      base_audit_metadata.merge(
        error_class: error.class.name,
        rack_attack_target: rack_attack_target,
        source_security_event_id: source_security_event&.id
      ).compact
    end

    def base_audit_metadata
      {
        operation: operation,
        ip_address: ip_address || raw_ip_address.to_s
      }.merge(reauthentication_metadata)
    end

    def operation_metadata
      {
        source: "admin_security_event",
        operation: operation,
        source_security_event_id: source_security_event&.id
      }.compact
    end

    def reauthentication_metadata
      return {} unless fresh_passkey_reauthentication?

      {
        reauthenticated: true,
        reauthentication_method: reauthentication[:method],
        reauthenticated_at: reauthenticated_at
      }
    end

    def source_security_event_ip_mismatch?
      return false if source_security_event.blank?

      source_ip = Security::IpAddress.normalize(source_security_event.ip_address)
      source_ip.present? && source_ip != ip_address
    end

    def current_admin_ip_block_forbidden?
      return false unless operation == "manual_ip_block"

      request_ip = Security::IpAddress.normalize(request&.remote_ip)
      request_ip.present? && request_ip == ip_address
    end

    def parsed_expires_at
      return @parsed_expires_at if defined?(@parsed_expires_at)

      @parsed_expires_at =
        if expires_at.blank?
          nil
        else
          Time.zone.parse(expires_at.to_s)
        end
    rescue ArgumentError, TypeError
      raise ValidationError, "expires_at_invalid"
    end

    def security_ip_block_from(result)
      result.respond_to?(:block) ? result.block : nil
    end

    def fresh_passkey_reauthentication?
      Admin.passkey_reauth_fresh?(reauthentication)
    end

    def reauthenticated_at
      Admin.passkey_reauthenticated_at(reauthentication)
    end

    def confirmation_valid?
      confirmation == operation_config.fetch(:confirmation)
    end

    def operation_config
      OPERATIONS[operation]
    end

    def target_uid
      return if (ip_address || raw_ip_address.to_s).blank?

      "ip:#{ip_address || raw_ip_address}"
    end

    def error_code_for(error)
      return error.message if error.is_a?(ValidationError) && error.message.present?
      return error.message if error.is_a?(Security::ValidationError) && error.message.present?

      "ip_access_operation_failed"
    end
  end
end
