require "openssl"

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
      "force_two_factor_reset" => {
        action: "admin.users.force_two_factor_reset",
        confirmation: "RESET 2FA",
        self_forbidden: true,
        admin_target_forbidden: true
      },
      "force_password_reset_instruction" => {
        action: "admin.users.force_password_reset_instruction",
        confirmation: "SEND PASSWORD RESET",
        self_forbidden: true,
        admin_target_forbidden: true,
        guest_target_forbidden: true,
        unconfirmed_target_forbidden: true
      },
      "admin_email_change_recovery" => {
        action: "admin.users.account_recovery_email_change",
        confirmation: "CHANGE RECOVERY EMAIL",
        self_forbidden: true,
        admin_target_forbidden: true,
        guest_target_forbidden: true,
        unconfirmed_target_forbidden: true,
        recovery_email_required: true
      },
      "revoke_sessions" => {
        action: "admin.users.session_revoke",
        confirmation: "REVOKE SESSIONS",
        self_forbidden: true,
        admin_target_forbidden: true
      },
      "delete_user" => {
        action: "admin.users.delete",
        confirmation: "DELETE USER",
        self_forbidden: true,
        admin_target_forbidden: true,
        email_confirmation_required: true
      }
    }.freeze

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
      @confirmation = confirmation
    end

    def call
      validate!

      audit_log = nil
      before_state = before_state_for_operation
      after_state = nil

      if operation == "force_password_reset_instruction"
        execute_operation!
        after_state = after_state_for_operation
        audit_log = record_success_audit!(before_state: before_state, after_state: after_state)
      else
        User.transaction do
          execute_operation!
          before_state = @account_deletion_summary if operation == "delete_user"
          after_state = after_state_for_operation
          audit_log = record_success_audit!(before_state: before_state, after_state: after_state)
        end
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
      raise ValidationError, "guest_target_forbidden" if guest_target_forbidden?
      raise ValidationError, "unconfirmed_target_forbidden" if unconfirmed_target_forbidden?
      raise ValidationError, "target_already_locked" if operation == "lock_user" && user_locked?
      raise ValidationError, "target_not_locked" if operation == "unlock_user" && !user_locked?
      raise ValidationError, "passkeys_missing" if operation == "force_passkey_reset" && user.passkeys.none?
      raise ValidationError, "two_factor_missing" if operation == "force_two_factor_reset" && two_factor_missing?
      validate_recovery_email! if recovery_email_required?
      raise ValidationError, "confirmation_email_required" if email_confirmation_required? && !confirmation_email_valid?
    end

    def execute_operation!
      case operation
      when "lock_user"
        user.lock_access!(send_instructions: false)
      when "unlock_user"
        user.unlock_access!
      when "force_passkey_reset"
        user.passkeys.destroy_all
      when "force_two_factor_reset"
        user.totp_credential&.destroy!
        user.recovery_codes.delete_all
        user.increment!(:session_version)
        @revoked_sessions_count = UserSessions.mark_revoked_for_user(user: user)
      when "force_password_reset_instruction"
        @reset_password_sent_at_before = user.reset_password_sent_at
        _raw_reset_token = user.send_reset_password_instructions
        @reset_password_delivery_requested = true
        @reset_password_sent_at_after = user.reload.reset_password_sent_at
      when "admin_email_change_recovery"
        @old_email_digest = email_digest(user.email)
        @new_email_digest = email_digest(recovery_email)
        @session_version_before = user.session_version
        user.update!(email: recovery_email)
        user.increment!(:session_version)
        @revoked_sessions_count = UserSessions.mark_revoked_for_user(user: user)
        user.reload
        @unconfirmed_email_digest = email_digest(user.unconfirmed_email)
        @session_version_after = user.session_version
      when "revoke_sessions"
        user.increment!(:session_version)
        @revoked_sessions_count = UserSessions.mark_revoked_for_user(user: user)
      when "delete_user"
        deletion_result = Users.delete_account(
          user: user,
          actor: actor,
          reason: reason,
          request: request,
          audit: false
        )
        @account_deletion_summary = deletion_result.summary
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
        before_state: before_state_for_operation,
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
      when "force_two_factor_reset"
        metadata.merge(
          had_totp_before: before_state[:totp_credential_present],
          had_totp_after: after_state[:totp_credential_present],
          recovery_codes_count_before: before_state[:recovery_codes_count],
          recovery_codes_count_after: after_state[:recovery_codes_count],
          unused_recovery_codes_count_before: before_state[:unused_recovery_codes_count],
          unused_recovery_codes_count_after: after_state[:unused_recovery_codes_count],
          revoked_sessions_count: @revoked_sessions_count.to_i
        )
      when "force_password_reset_instruction"
        metadata.merge(
          email_digest: email_digest(user.email),
          reset_password_sent_at_before: @reset_password_sent_at_before,
          reset_password_sent_at_after: @reset_password_sent_at_after,
          delivery_requested: @reset_password_delivery_requested == true
        )
      when "admin_email_change_recovery"
        metadata.merge(
          old_email_digest: @old_email_digest,
          new_email_digest: @new_email_digest,
          unconfirmed_email_digest: @unconfirmed_email_digest,
          session_version_before: @session_version_before,
          session_version_after: @session_version_after,
          revoked_sessions_count: @revoked_sessions_count.to_i
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
        latest_passkey_last_used_at: current_user.passkeys.maximum(:last_used_at),
        totp_credential_present: current_user.totp_credential.present?,
        totp_enabled: current_user.totp_credential&.confirmed? == true,
        recovery_codes_count: current_user.recovery_codes.count,
        unused_recovery_codes_count: current_user.recovery_codes.where(used_at: nil).count
      }.tap do |state|
        state[:session_version] = current_user.session_version if current_user.has_attribute?(:session_version)
      end
    rescue ActiveRecord::RecordNotFound
      {}
    end

    def before_state_for_operation
      return account_deletion_summary_for(user) if operation == "delete_user"

      safe_user_state
    end

    def after_state_for_operation
      return { deleted: true } if operation == "delete_user"

      user.reload
      safe_user_state
    end

    def account_deletion_summary_for(target_user)
      return {} unless target_user

      {
        user_id: target_user.id,
        email_digest: email_digest(target_user.email),
        admin: target_user.admin?,
        guest: target_user.guest?,
        receipts_count: target_user.receipts.count,
        passkeys_count: target_user.passkeys.count,
        user_sessions_count: target_user.user_sessions.count,
        notifications_count: target_user.notifications.count,
        avatar_attached: target_user.avatar.attached?
      }
    end

    def email_digest(email)
      Users.account_deletion_email_digest(email)
    end

    def user_locked?
      user.locked_at.present?
    end

    def two_factor_missing?
      user.totp_credential.blank? && user.recovery_codes.none?
    end

    def self_operation_forbidden?
      operation_config.fetch(:self_forbidden) && actor.id == user.id
    end

    def admin_target_forbidden?
      operation_config.fetch(:admin_target_forbidden) && user.admin?
    end

    def guest_target_forbidden?
      operation_config.fetch(:guest_target_forbidden, false) && user.guest?
    end

    def unconfirmed_target_forbidden?
      operation_config.fetch(:unconfirmed_target_forbidden, false) && !user.confirmed?
    end

    def confirmation_valid?
      confirmation_text == operation_config.fetch(:confirmation)
    end

    def email_confirmation_required?
      operation_config.fetch(:email_confirmation_required, false)
    end

    def recovery_email_required?
      operation_config.fetch(:recovery_email_required, false)
    end

    def validate_recovery_email!
      raise ValidationError, "recovery_email_required" if recovery_email.blank?
      raise ValidationError, "recovery_email_invalid" unless recovery_email.match?(Devise.email_regexp)
      raise ValidationError, "recovery_email_unchanged" if recovery_email == user.email.to_s.strip.downcase
      raise ValidationError, "recovery_email_taken" if recovery_email_taken?
    end

    def recovery_email_taken?
      normalized = recovery_email
      registered = User.where("LOWER(email) = ?", normalized)
      pending = User.where("LOWER(unconfirmed_email) = ?", normalized)
      registered = registered.where.not(id: user.id)
      pending = pending.where.not(id: user.id)
      registered.exists? || pending.exists?
    end

    def confirmation_email_valid?
      ActiveSupport::SecurityUtils.secure_compare(
        confirmation_email,
        user.email.to_s
      )
    rescue ArgumentError
      false
    end

    def confirmation_text
      return confirmation_hash[:text].to_s.strip if confirmation_hash.present?

      confirmation.to_s.strip
    end

    def confirmation_email
      return confirmation_hash[:email].to_s.strip if confirmation_hash.present?

      ""
    end

    def recovery_email
      confirmation_hash[:new_email].to_s.strip.downcase
    end

    def confirmation_hash
      case confirmation
      when ActionController::Parameters
        confirmation.to_unsafe_h.with_indifferent_access
      when Hash
        confirmation.with_indifferent_access
      else
        {}
      end
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
      Admin.passkey_reauth_fresh?(reauthentication, user: actor)
    end

    def reauthenticated_at
      Admin.passkey_reauthenticated_at(reauthentication)
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
