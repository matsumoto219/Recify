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
      "receipt_analysis.full_reanalyze",
      "receipt_analysis.ocr_retry",
      "receipt_analysis.ai_retry",
      "receipt_analysis.finalize_retry",
      "admin.passkey_reauthentication.succeeded",
      "admin.passkey_reauthentication.failed"
    ].freeze

    LOCKED_FUTURE_OPERATIONS = [
      "feature flag変更",
      "timeout変更",
      "queue pause/resume",
      "external service override",
      "system settings",
      "admin権限変更",
      "user BAN/delete"
    ].freeze

    POLICY_ITEMS = [
      "fresh passkey reauthentication required",
      "reason required",
      "AuditLog required",
      "service/facade only",
      "no raw OCR / prompt / raw AI / secret"
    ].freeze

    Result = Struct.new(
      :policy_items,
      :queues,
      :recurring_tasks,
      :audit_actions,
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
        policy_items: POLICY_ITEMS,
        queues: QUEUES,
        recurring_tasks: recurring_tasks,
        audit_actions: AUDIT_ACTIONS,
        locked_future_operations: LOCKED_FUTURE_OPERATIONS
      )
    end

    private

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
