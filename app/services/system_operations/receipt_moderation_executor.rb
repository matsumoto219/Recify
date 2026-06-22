# frozen_string_literal: true

module SystemOperations
  class ReceiptModerationExecutor
    OPERATIONS = {
      "quarantine" => {
        action: "admin.receipts.quarantine",
        confirmation: "QUARANTINE RECEIPT"
      },
      "release" => {
        action: "admin.receipts.release",
        confirmation: "RELEASE RECEIPT"
      }
    }.freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(operation:, receipt:, actor:, reason:, request:, reauthentication:, confirmation:, source_security_event: nil)
      @operation = operation.to_s
      @receipt = receipt
      @actor = actor
      @reason = reason.to_s.strip
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
      @confirmation = confirmation.to_s.strip
      @source_security_event = source_security_event
    end

    def call
      validate!

      audit_log = nil
      before_state = receipt_state
      after_state = nil

      Receipt.transaction do
        execute_operation!
        receipt.reload
        after_state = receipt_state
        audit_log = record_success_audit!(before_state: before_state, after_state: after_state)
      end

      Result.new(
        success: true,
        operation: operation,
        receipt: receipt,
        receipt_moderation_result: moderation_result(before_state:, after_state:),
        before_state: before_state,
        after_state: after_state,
        audit_log: audit_log
      )
    rescue StandardError => e
      audit_log = record_failed_audit!(e)

      Result.new(
        success: false,
        operation: operation,
        receipt: receipt,
        receipt_moderation_result: nil,
        before_state: safe_receipt_state,
        after_state: {},
        audit_log: audit_log,
        error_code: error_code_for(e),
        error_message: e.message
      )
    end

    private

    attr_reader :operation, :receipt, :actor, :reason, :request, :reauthentication,
                :confirmation, :source_security_event

    def validate!
      raise ValidationError, "unknown_operation" unless operation_config
      raise ValidationError, "target_receipt_required" unless receipt
      raise ValidationError, "actor_required" unless actor
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "reauthentication_required" unless fresh_passkey_reauthentication?
      raise ValidationError, "confirmation_required" unless confirmation_valid?
      raise ValidationError, "receipt_already_quarantined" if operation == "quarantine" && !receipt.moderation_active?
      raise ValidationError, "receipt_not_quarantined" if operation == "release" && !receipt.moderation_quarantined?
    end

    def execute_operation!
      case operation
      when "quarantine"
        receipt.quarantine!(
          actor: actor,
          reason: reason,
          source_security_event: source_security_event
        )
      when "release"
        receipt.release_quarantine!(
          actor: actor,
          reason: reason
        )
      end
    end

    def record_success_audit!(before_state:, after_state:)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: operation_config.fetch(:action),
        target: receipt,
        target_uid: target_uid,
        reason: reason,
        outcome: "succeeded",
        metadata: audit_metadata(before_state: before_state, after_state: after_state),
        before_state: before_state,
        after_state: after_state,
        request: request
      )
    end

    def record_failed_audit!(error)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: operation_config&.fetch(:action) || "admin.receipts.unknown_operation",
        target: receipt,
        target_uid: target_uid,
        reason: reason.presence,
        outcome: "failed",
        error_code: error_code_for(error),
        metadata: failure_audit_metadata(error),
        before_state: safe_receipt_state,
        after_state: {},
        request: request
      )
    end

    def audit_metadata(before_state:, after_state:)
      base_audit_metadata.merge(
        before_status: before_state[:moderation_status],
        after_status: after_state[:moderation_status],
        source_security_event_id: source_security_event&.id
      ).compact
    end

    def failure_audit_metadata(error)
      base_audit_metadata.merge(
        error_class: error.class.name,
        source_security_event_id: source_security_event&.id
      ).compact
    end

    def base_audit_metadata
      {
        operation: operation,
        receipt_id: receipt&.id,
        receipt_public_id: receipt&.public_id,
        receipt_display_id: receipt&.display_id,
        target_user_id: receipt&.user_id,
        image_attached: receipt&.image&.attached?,
        image_purged: receipt&.image_purged?
      }.merge(reauthentication_metadata)
    end

    def receipt_state
      {
        receipt_id: receipt.id,
        receipt_public_id: receipt.public_id,
        receipt_display_id: receipt.display_id,
        target_user_id: receipt.user_id,
        receipt_status: receipt.status,
        moderation_status: receipt.moderation_status,
        quarantined_at: receipt.quarantined_at,
        quarantined_by_id: receipt.quarantined_by_id,
        quarantine_source_security_event_id: receipt.quarantine_source_security_event_id,
        quarantine_released_at: receipt.quarantine_released_at,
        quarantine_released_by_id: receipt.quarantine_released_by_id,
        image_attached: receipt.image.attached?,
        image_purged: receipt.image_purged?
      }
    end

    def safe_receipt_state
      return {} unless receipt

      receipt.reload if receipt.persisted?
      receipt_state
    rescue StandardError
      {}
    end

    def moderation_result(before_state:, after_state:)
      {
        operation: operation,
        receipt_id: receipt.id,
        receipt_public_id: receipt.public_id,
        before_status: before_state[:moderation_status],
        after_status: after_state[:moderation_status]
      }
    end

    def reauthentication_metadata
      return {} unless fresh_passkey_reauthentication?

      {
        reauthenticated: true,
        reauthentication_method: reauthentication[:method],
        reauthenticated_at: reauthenticated_at
      }
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
      return if receipt&.public_id.blank?

      "receipt:#{receipt.public_id}"
    end

    def error_code_for(error)
      return error.message if error.is_a?(ValidationError) && error.message.present?

      "receipt_moderation_operation_failed"
    end
  end
end
