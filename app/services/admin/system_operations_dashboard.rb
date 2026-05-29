module Admin
  class SystemOperationsDashboard
    QUEUES = %w[
      default
      receipt_ocr
      receipt_ai
      receipt_finalize
    ].freeze

    AUDIT_ACTIONS = [
      "receipt_analysis_runs.cleanup_stale.execute",
      "receipt_analysis_runs.cleanup_expired.execute",
      "receipt_analysis_runs.cleanup_stale.dry_run",
      "receipt_analysis_runs.cleanup_expired.dry_run",
      "user_sessions.retention_cleanup.dry_run",
      "audit_logs.retention_cleanup.dry_run",
      "receipt_analysis.full_reanalyze",
      "receipt_analysis.ocr_retry",
      "receipt_analysis.ai_retry",
      "receipt_analysis.finalize_retry",
      "admin.passkey_reauthentication.succeeded",
      "admin.passkey_reauthentication.failed"
    ].freeze

    LOCKED_FUTURE_OPERATION_KEYS = %i[
      feature_flags
      timeouts
      queue_control
      external_service_override
      system_settings
      admin_roles
      user_limits_and_deletion
    ].freeze

    POLICY_ITEM_KEYS = %i[
      passkey_reauthentication
      reason_required
      audit_log
      dedicated_procedure
      secrets_hidden
    ].freeze

    Result = Struct.new(
      :policy_items,
      :queues,
      :recurring_tasks,
      :audit_actions,
      :audit_log_retention_policies,
      :locked_future_operations,
      keyword_init: true
    )

    class << self
      def call
        new.call
      end
    end

    def call
      Result.new(
        policy_items: policy_items,
        queues: QUEUES,
        recurring_tasks: recurring_tasks,
        audit_actions: AUDIT_ACTIONS,
        audit_log_retention_policies: audit_log_retention_policies,
        locked_future_operations: locked_future_operations
      )
    end

    private

    def policy_items
      POLICY_ITEM_KEYS.map do |key|
        I18n.t("admin.system_operations_dashboard.policy_items.#{key}")
      end
    end

    def locked_future_operations
      LOCKED_FUTURE_OPERATION_KEYS.map do |key|
        I18n.t("admin.system_operations_dashboard.locked_future_operations.#{key}")
      end
    end

    def audit_log_retention_policies
      AuditLogs::RetentionPolicy.categories.map do |category|
        {
          category: category.to_s,
          label: retention_category_label(category),
          retention: retention_label(category),
          actions_count: AuditLogs::RetentionPolicy.actions_for(category).size,
          excluded: AuditLogs::RetentionPolicy.excluded?(category)
        }
      end
    end

    def retention_category_label(category)
      I18n.t(
        "admin.system_operations_dashboard.retention_categories.#{category}",
        default: category.to_s
      )
    end

    def retention_label(category)
      return I18n.t("admin.system_operations_dashboard.retention.excluded") if AuditLogs::RetentionPolicy.excluded?(category)

      retention = AuditLogs::RetentionPolicy.retention_for(category)
      return "-" if retention.blank?

      I18n.t("admin.system_operations_dashboard.retention.days", count: retention / 1.day)
    end

    def recurring_tasks
      production_recurring_config.filter_map do |key, config|
        next unless dry_run_task?(config)

        {
          key: key,
          class_name: config["class"],
          queue: config["queue"],
          schedule: config["schedule"],
          dry_run: true
        }
      end
    end

    def production_recurring_config
      config = YAML.safe_load(
        Rails.root.join("config/recurring.yml").read,
        permitted_classes: [],
        aliases: false
      )
      config.fetch("production", {})
    rescue Errno::ENOENT, Psych::Exception
      {}
    end

    def dry_run_task?(config)
      Array(config["args"]).any? do |arg|
        arg.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(arg["dry_run"])
      end
    end
  end
end
