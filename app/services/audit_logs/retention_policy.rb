module AuditLogs
  module RetentionPolicy
    USER_DELETE_ACTIONS = %w[
      admin.users.delete
    ].freeze

    HIGH_RISK_ADMIN_ACTIONS = %w[
      admin.users.lock
      admin.users.unlock
      admin.users.force_passkey_reset
      admin.users.force_two_factor_reset
      admin.users.session_revoke
      admin.ip_access.manual_block
      admin.ip_access.manual_unblock
      admin.ip_access.rack_attack_ban_reset_requested
      admin.ip_access.rack_attack_ban_reset
      admin.receipts.hard_delete
      receipt_analysis.retry_requested
      receipt_analysis.full_reanalyze
      receipt_analysis.ocr_retry
      receipt_analysis.ai_retry
      receipt_analysis.finalize_retry
      system_settings.update
    ].freeze

    CLEANUP_EXECUTE_ACTIONS = %w[
      contact_requests.retention_cleanup.execute
      receipt_analysis_runs.cleanup_stale.execute
      receipt_analysis_runs.cleanup_expired.execute
      receipt_images.purge.execute
      security_events.retention_cleanup.execute
    ].freeze

    PASSKEY_REAUTH_ACTIONS = %w[
      admin.passkey_reauthentication.succeeded
      admin.passkey_reauthentication.failed
    ].freeze

    SYSTEM_DRY_RUN_ACTIONS = %w[
      contact_requests.retention_cleanup.dry_run
      receipt_analysis_runs.cleanup_stale.dry_run
      receipt_analysis_runs.cleanup_expired.dry_run
      receipt_images.purge.dry_run
      user_sessions.retention_cleanup.dry_run
      audit_logs.retention_cleanup.dry_run
      security_events.retention_cleanup.dry_run
    ].freeze

    CLEANUP_ACTIONS = (
      CLEANUP_EXECUTE_ACTIONS + SYSTEM_DRY_RUN_ACTIONS
    ).freeze

    RETENTIONS = {
      user_delete: nil,
      high_risk_admin: 365.days,
      cleanup_execute: 365.days,
      cleanup_failed: 180.days,
      passkey_reauth: 90.days,
      system_dry_run: 30.days,
      routine_system: 90.days
    }.freeze

    RETENTION_SETTING_KEYS = {
      high_risk_admin: "retention.audit_logs_high_risk_admin_days",
      cleanup_execute: "retention.audit_logs_cleanup_execute_days",
      cleanup_failed: "retention.audit_logs_cleanup_failed_days",
      passkey_reauth: "retention.audit_logs_passkey_reauth_days",
      system_dry_run: "retention.audit_logs_system_dry_run_days",
      routine_system: "retention.audit_logs_routine_system_days"
    }.freeze

    ACTIONS = {
      user_delete: USER_DELETE_ACTIONS,
      high_risk_admin: HIGH_RISK_ADMIN_ACTIONS,
      cleanup_execute: CLEANUP_EXECUTE_ACTIONS,
      cleanup_failed: CLEANUP_ACTIONS,
      passkey_reauth: PASSKEY_REAUTH_ACTIONS,
      system_dry_run: SYSTEM_DRY_RUN_ACTIONS,
      routine_system: []
    }.freeze

    class << self
      def category_for(action:, outcome: nil)
        action = action.to_s
        return :user_delete if USER_DELETE_ACTIONS.include?(action)
        return :cleanup_failed if outcome.to_s == "failed" && CLEANUP_ACTIONS.include?(action)
        return :high_risk_admin if HIGH_RISK_ADMIN_ACTIONS.include?(action)
        return :cleanup_execute if CLEANUP_EXECUTE_ACTIONS.include?(action)
        return :passkey_reauth if PASSKEY_REAUTH_ACTIONS.include?(action)
        return :system_dry_run if SYSTEM_DRY_RUN_ACTIONS.include?(action)

        nil
      end

      def retention_for(category)
        category = category.to_sym
        return RETENTIONS.fetch(category) if excluded?(category)

        key = RETENTION_SETTING_KEYS.fetch(category)
        SystemSettings.limit_for(key).days
      rescue KeyError, SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        RETENTIONS.fetch(category)
      end

      def excluded?(category)
        category.to_sym == :user_delete
      end

      def categories
        RETENTIONS.keys
      end

      def cleanup_categories
        categories.reject { |category| excluded?(category) }
      end

      def actions_for(category)
        ACTIONS.fetch(category.to_sym)
      end

      def cutoff_for(category, now: Time.current)
        retention = retention_for(category)
        return if retention.blank?

        now - retention
      end
    end
  end
end
