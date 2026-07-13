module SystemOperations
  class UserLimitUpdateExecutor
    ACTION = "admin.users.limit_update".freeze
    CONFIRMATION_TEXT = "UPDATE USER LIMIT".freeze

    class << self
      def call(user:, key:, value:, enabled:, expires_at:, actor:, reason:, request:, reauthentication:, confirmation:)
        new(
          user: user,
          key: key,
          value: value,
          enabled: enabled,
          expires_at: expires_at,
          actor: actor,
          reason: reason,
          request: request,
          reauthentication: reauthentication,
          confirmation: confirmation
        ).call
      end
    end

    def initialize(user:, key:, value:, enabled:, expires_at:, actor:, reason:, request:, reauthentication:, confirmation:)
      @user = user
      @key = key.to_s.strip
      @raw_value = value
      @raw_enabled = enabled
      @raw_expires_at = expires_at
      @actor = actor
      @reason = reason.to_s.strip
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
      @confirmation = confirmation.to_s.strip
    end

    def call
      override = nil
      audit_log = nil
      before_state = nil
      after_state = nil

      SystemSettingDependencyLock.call(groups: SystemSettings.dependency_lock_groups_for(key)) do
        validate!
        before_state = current_state
        override = update_override!
        after_state = current_state
        audit_log = record_success_audit!(override: override, before_state: before_state, after_state: after_state)
      end

      Result.new(
        success: true,
        operation: ACTION,
        user_limit_override: override,
        before_state: before_state,
        after_state: after_state,
        audit_log: audit_log
      )
    rescue StandardError => e
      audit_log = record_failed_audit!(e)

      Result.new(
        success: false,
        operation: ACTION,
        user_limit_override: nil,
        before_state: safe_current_state,
        after_state: {},
        audit_log: audit_log,
        error_code: error_code_for(e),
        error_message: e.message
      )
    end

    private

    attr_reader :user, :key, :raw_value, :raw_enabled, :raw_expires_at, :actor, :reason, :request, :reauthentication, :confirmation

    def validate!
      raise ValidationError, "unknown_key" unless UserLimits.valid_key?(key)
      raise ValidationError, "actor_required" unless actor
      raise ValidationError, "target_user_required" unless user
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "reauthentication_required" unless fresh_passkey_reauthentication?
      raise ValidationError, "confirmation_required" unless confirmation == CONFIRMATION_TEXT

      casted_value
      parsed_expires_at

      raise ValidationError, "self_limit_increase_forbidden" if self_target_increase?
      raise ValidationError, "admin_target_forbidden" if other_admin_target?
    end

    def update_override!
      override = user.user_limit_overrides.find_or_initialize_by(key: key)
      override.created_by_user ||= actor
      override.assign_attributes(
        value: UserLimits.stored_value(casted_value),
        enabled: enabled_value,
        expires_at: parsed_expires_at,
        updated_by_user: actor
      )
      override.save!
      override
    end

    def record_success_audit!(override:, before_state:, after_state:)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: ACTION,
        target: user,
        target_uid: target_uid,
        reason: reason,
        outcome: "succeeded",
        metadata: audit_metadata,
        before_state: before_state,
        after_state: after_state,
        request: request
      )
    end

    def record_failed_audit!(error)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: ACTION,
        target: user,
        target_uid: target_uid,
        reason: reason.presence,
        outcome: "failed",
        error_code: error_code_for(error),
        metadata: audit_metadata.merge(error_class: error.class.name),
        before_state: safe_current_state,
        after_state: {},
        request: request
      )
    end

    def current_state
      entry = UserLimits.entry_for(user: user, key: key)
      override = user.user_limit_overrides.find_by(key: key)

      {
        user_id: user.id,
        key: key,
        limit_value: entry.value,
        source: entry.source,
        override_enabled: override&.enabled,
        override_value: override&.integer_value,
        expires_at: override&.expires_at
      }.compact
    end

    def safe_current_state
      return {} unless user && UserLimits.valid_key?(key)

      current_state
    rescue StandardError
      {}
    end

    def audit_metadata
      {
        key: UserLimits.valid_key?(key) ? key : "unknown",
        enabled: enabled_value,
        expires_at: parsed_expires_at
      }.merge(reauthentication_metadata)
    rescue StandardError
      reauthentication_metadata
    end

    def reauthentication_metadata
      return {} unless fresh_passkey_reauthentication?

      {
        reauthenticated: true,
        reauthentication_method: reauthentication[:method],
        reauthenticated_at: reauthenticated_at
      }
    end

    def self_target_increase?
      return false if admin_self_target?
      return false unless actor.id == user.id
      return false unless enabled_value

      casted_value > UserLimits.effective_limit(user: user, key: key)
    end

    def admin_self_target?
      actor.id == user.id && actor.admin? && user.admin?
    end

    def other_admin_target?
      user.admin? && actor.id != user.id
    end

    def casted_value
      @casted_value ||= UserLimits.cast_value(key, { "value" => raw_value })
    end

    def enabled_value
      return true if raw_enabled.nil?

      ActiveModel::Type::Boolean.new.cast(raw_enabled)
    end

    def parsed_expires_at
      return nil if raw_expires_at.blank?

      Time.zone.parse(raw_expires_at.to_s)
    rescue ArgumentError, TypeError
      raise ValidationError, "expires_at_invalid"
    end

    def fresh_passkey_reauthentication?
      Admin.passkey_reauth_fresh?(reauthentication, user: actor)
    end

    def reauthenticated_at
      Admin.passkey_reauthenticated_at(reauthentication)
    end

    def target_uid
      "user:#{user.id}" if user
    end

    def error_code_for(error)
      return error.message if error.is_a?(ValidationError) && error.message.present?
      return error.message if error.is_a?(UserLimits::ValidationError) && error.message.present?

      "user_limit_update_failed"
    end
  end
end
