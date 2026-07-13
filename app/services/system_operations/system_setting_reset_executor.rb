module SystemOperations
  class SystemSettingResetExecutor
    ACTION = "system_settings.reset"

    class << self
      def call(key:, actor:, reason:, request:, reauthentication:, confirmation: nil)
        new(
          key: key,
          actor: actor,
          reason: reason,
          request: request,
          reauthentication: reauthentication,
          confirmation: confirmation
        ).call
      end
    end

    def initialize(key:, actor:, reason:, request:, reauthentication:, confirmation: nil)
      @key = key.to_s.strip
      @actor = actor
      @reason = reason.to_s.strip
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
      @confirmation = confirmation
    end

    def call
      validate!

      setting = nil
      audit_log = nil
      before_state = nil
      after_state = nil
      default_value = nil

      SystemSettingDependencyLock.call(groups: SystemSettings.dependency_lock_groups_for(key)) do
        setting = SystemSetting.lock.find_by(key: key)
        raise ValidationError, "setting_already_default" unless setting

        before_state = current_state
        default_value = SystemSettings.cast_update_value(key, definition.default)
        after_state = state_for(value: default_value, source: "default")
        setting.destroy!
        audit_log = record_success_audit!(
          setting: setting,
          before_state: before_state,
          after_state: after_state
        )
      end

      Result.new(
        success: true,
        operation: ACTION,
        setting: setting,
        value: default_value,
        before_state: before_state,
        after_state: after_state,
        audit_log: audit_log
      )
    rescue StandardError => e
      audit_log = record_failed_audit!(e)

      Result.new(
        success: false,
        operation: ACTION,
        setting: nil,
        value: nil,
        before_state: safe_current_state,
        after_state: {},
        audit_log: audit_log,
        error_code: error_code_for(e),
        error_message: e.message,
        error_details: error_details_for(e)
      )
    end

    private

    attr_reader :key, :actor, :reason, :request, :reauthentication, :confirmation

    def validate!
      raise ValidationError, "unknown_key" unless SystemSettings.valid_key?(key)
      raise ValidationError, "setting_not_editable" unless definition.editable == true
      raise ValidationError, "actor_required" unless actor
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "reauthentication_required" unless fresh_passkey_reauthentication?
      raise ValidationError, "confirmation_required" if confirmation_required? && !confirmed?
    end

    def record_success_audit!(setting:, before_state:, after_state:)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: ACTION,
        target: setting,
        target_uid: key,
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
        target_uid: failed_target_uid,
        reason: reason.presence,
        outcome: "failed",
        error_code: error_code_for(error),
        metadata: failure_audit_metadata(error),
        before_state: safe_current_state,
        after_state: {},
        request: request
      )
    end

    def audit_metadata
      definition_metadata.merge(reauthentication_metadata)
    end

    def failure_audit_metadata(error)
      definition_metadata
        .merge(error_class: error.class.name)
        .merge(reauthentication_metadata)
    end

    def definition_metadata
      return {} unless SystemSettings.valid_key?(key)

      {
        key: definition.key,
        category: definition.category,
        value_type: definition.value_type,
        risk_level: definition.risk_level
      }
    end

    def current_state
      entry = SystemSettings.fetch(key)
      state_for(value: entry.current_value, source: entry.source)
    end

    def safe_current_state
      return {} unless SystemSettings.valid_key?(key)

      current_state
    rescue StandardError
      {}
    end

    def state_for(value:, source:)
      {
        value: SystemSettings.audit_value(value),
        source: source
      }
    end

    def definition
      @definition ||= SystemSettings.definition_for(key)
    end

    def confirmation_required?
      definition.requires_confirmation == true || definition.risk_level.to_s == "high"
    end

    def confirmed?
      ActiveModel::Type::Boolean.new.cast(confirmation)
    end

    def reauthentication_metadata
      return {} unless fresh_passkey_reauthentication?

      {
        reauthenticated: true,
        reauthentication_method: reauthentication[:method],
        reauthenticated_at: Admin.passkey_reauthenticated_at(reauthentication)
      }
    end

    def fresh_passkey_reauthentication?
      Admin.passkey_reauth_fresh?(reauthentication, user: actor)
    end

    def error_code_for(error)
      return error.message if error.is_a?(ValidationError) && error.message.present?
      return error.message if error.is_a?(SystemSettings::UnknownKeyError) && error.message.present?
      return error.message if error.is_a?(SystemSettings::ValidationError) && error.message.present?

      "system_setting_reset_failed"
    end

    def error_details_for(error)
      return error.details if error.respond_to?(:details)

      {}
    end

    def failed_target_uid
      return key if SystemSettings.valid_key?(key)

      nil
    end
  end
end
