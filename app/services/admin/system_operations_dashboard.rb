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

    LOCKED_FUTURE_OPERATIONS = [
      "機能公開設定の変更",
      "処理時間設定の変更",
      "キューの一時停止・再開",
      "外部サービス状態の切り替え",
      "システム設定の変更",
      "管理者権限の変更",
      "ユーザー利用制限・削除"
    ].freeze

    POLICY_ITEMS = [
      "パスキーによる再認証が必要",
      "実行理由の入力が必要",
      "監査ログに記録",
      "専用の管理手順で実行",
      "OCR原文・AI応答・機密情報は表示しない"
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
        policy_items: POLICY_ITEMS,
        queues: QUEUES,
        recurring_tasks: recurring_tasks,
        audit_actions: AUDIT_ACTIONS,
        audit_log_retention_policies: audit_log_retention_policies,
        locked_future_operations: LOCKED_FUTURE_OPERATIONS
      )
    end

    private

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
      {
        user_delete: "退会代行ログ",
        high_risk_admin: "重要な管理操作",
        cleanup_execute: "Cleanup実行",
        cleanup_failed: "Cleanup失敗",
        passkey_reauth: "パスキー再認証",
        system_dry_run: "定期確認ログ",
        routine_system: "通常システム操作"
      }.fetch(category, category.to_s)
    end

    def retention_label(category)
      return "自動整理の対象外" if AuditLogs::RetentionPolicy.excluded?(category)

      retention = AuditLogs::RetentionPolicy.retention_for(category)
      return "-" if retention.blank?

      "#{retention / 1.day}日"
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
