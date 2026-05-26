module SystemOperations
  class UserOperationExecutor
    OPERATIONS = {
      "lock_user" => {
        action: "admin.users.lock",
        confirmation: "LOCK USER",
        self_forbidden: true,
        admin_target_forbidden: true
      },
      "unlock_user" => {
        action: "admin.users.unlock",
        confirmation: "UNLOCK USER",
        self_forbidden: false,
        admin_target_forbidden: true
      },
      "force_passkey_reset" => {
        action: "admin.users.force_passkey_reset",
        confirmation: "RESET PASSKEYS",
        self_forbidden: true,
        admin_target_forbidden: true
      },
      "revoke_sessions" => {
        action: "admin.users.session_revoke",
        confirmation: "REVOKE SESSIONS",
        self_forbidden: true,
        admin_target_forbidden: true
      }
    }.freeze

    REAUTHENTICATION_WINDOW = 5.minutes

    class << self
      def call(operation:, user:, actor:, reason:, request:, reauthentication:, confirmation:)
        new(
          operation: operation,
          user: user,
          actor: actor,
          reason: reason,
          request: request,
          reauthentication: reauthentication,
          confirmation: confirmation
        ).call
      end
    end

    def initialize(operation:, user:, actor:, reason:, request:, reauthentication:, confirmation:)
      @operation = operation.to_s
      @user = user
      @actor = actor
      @reason = reason.to_s.strip
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
      @confirmation = confirmation.to_s.strip
    end

    def call
      validate!

      audit_log = nil
      before_state = safe_user_state
      after_state = nil

      User.transaction do
        execute_operation!
        user.reload
        after_state = safe_user_state
        audit_log = record_success_audit!(before_state: before_state, after_state: after_state)
      end

      Result.new(
        success: true,
        operation: operation,
        before_state: before_state,
        after_state: after_state,
        audit_log: audit_log
      )
    rescue StandardError => e
      audit_log = record_failed_audit!(e)

      Result.new(
        success: false,
        operation: operation,
        before_state: safe_user_state,
        after_state: {},
        audit_log: audit_log,
        error_code: error_code_for(e),
        error_message: e.message
      )
    end

    private

    attr_reader :operation, :user, :actor, :reason, :request, :reauthentication, :confirmation

    def validate!
      raise ValidationError, "unknown_operation" unless operation_config
      raise ValidationError, "actor_required" unless actor
      raise ValidationError, "target_user_required" unless user
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "reauthentication_required" unless fresh_passkey_reauthentication?
      raise ValidationError, "confirmation_required" unless confirmation_valid?
      raise ValidationError, "self_operation_forbidden" if self_operation_forbidden?
      raise ValidationError, "admin_target_forbidden" if admin_target_forbidden?
      raise ValidationError, "target_already_locked" if operation == "lock_user" && user_locked?
      raise ValidationError, "target_not_locked" if operation == "unlock_user" && !user_locked?
      raise ValidationError, "passkeys_missing" if operation == "force_passkey_reset" && user.passkeys.none?
    end

    def execute_operation!
      case operation
      when "lock_user"
        user.lock_access!(send_instructions: false)
      when "unlock_user"
        user.unlock_access!
      when "force_passkey_reset"
        user.passkeys.destroy_all
      when "revoke_sessions"
        user.increment!(:session_version)
        @revoked_sessions_count = UserSessions.mark_revoked_for_user(user: user)
      end
    end

    def record_success_audit!(before_state:, after_state:)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: operation_config.fetch(:action),
        target: user,
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
        action: operation_config&.fetch(:action) || "admin.users.unknown_operation",
        target: user,
        target_uid: target_uid,
        reason: reason.presence,
        outcome: "failed",
        error_code: error_code_for(error),
        metadata: failure_audit_metadata(error),
        before_state: safe_user_state,
        after_state: {},
        request: request
      )
    end

    def base_audit_metadata
      {
        operation: operation
      }.merge(reauthentication_metadata)
    end

    def audit_metadata(before_state:, after_state:)
      metadata = base_audit_metadata

      case operation
      when "force_passkey_reset"
        metadata.merge(
          passkeys_count_before: before_state[:passkeys_count],
          passkeys_count_after: after_state[:passkeys_count],
          latest_passkey_last_used_at: before_state[:latest_passkey_last_used_at]
        )
      when "revoke_sessions"
        metadata.merge(revoked_sessions_count: @revoked_sessions_count.to_i)
      else
        metadata
      end
    end

    def failure_audit_metadata(error)
      base_audit_metadata.merge(error_class: error.class.name)
    end

    def safe_user_state
      return {} unless user

      current_user = user.persisted? ? user.reload : user
      {
        user_id: current_user.id,
        admin: current_user.admin?,
        guest: current_user.guest?,
        locked: current_user.locked_at.present?,
        failed_attempts: current_user.failed_attempts,
        locked_at: current_user.locked_at,
        passkeys_count: current_user.passkeys.count,
        latest_passkey_last_used_at: current_user.passkeys.maximum(:last_used_at)
      }.tap do |state|
        state[:session_version] = current_user.session_version if current_user.has_attribute?(:session_version)
      end
    rescue ActiveRecord::RecordNotFound
      {}
    end

    def user_locked?
      user.locked_at.present?
    end

    def self_operation_forbidden?
      operation_config.fetch(:self_forbidden) && actor.id == user.id
    end

    def admin_target_forbidden?
      operation_config.fetch(:admin_target_forbidden) && user.admin?
    end

    def confirmation_valid?
      confirmation == operation_config.fetch(:confirmation)
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
      reauthentication[:method] == "passkey" &&
        reauthenticated_at.present? &&
        reauthenticated_at >= REAUTHENTICATION_WINDOW.ago
    rescue ArgumentError, TypeError
      false
    end

    def reauthenticated_at
      value = reauthentication[:reauthenticated_at]
      value.respond_to?(:>=) ? value : Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def operation_config
      OPERATIONS[operation]
    end

    def target_uid
      "user:#{user.id}" if user
    end

    def error_code_for(error)
      return error.message if error.is_a?(ValidationError) && error.message.present?

      "user_operation_failed"
    end
  end
end
