module Admin
  class Dashboard
    RECEIPT_ATTENTION_STATUSES = %w[review_needed failed].freeze
    RETRY_AUDIT_ACTIONS = %w[
      receipt_analysis.full_reanalyze
      receipt_analysis.ocr_retry
      receipt_analysis.ai_retry
      receipt_analysis.finalize_retry
    ].freeze
    CLEANUP_EXECUTE_AUDIT_ACTIONS = %w[
      receipt_analysis_runs.cleanup_stale.execute
      receipt_analysis_runs.cleanup_expired.execute
      receipt_images.purge.execute
    ].freeze
    RECENT_WINDOW = 24.hours

    Result = Struct.new(
      :receipt_analysis,
      :cleanup,
      :audit,
      :contact_requests,
      :security,
      :external_services,
      :storage,
      :legal_documents,
      :database_status,
      :system_operations,
      :locked_future_operations,
      keyword_init: true
    )

    class << self
      def call(admin_user:)
        new(admin_user: admin_user).call
      end
    end

    def initialize(admin_user:)
      @admin_user = admin_user
    end

    def call
      system_dashboard = Admin.system_operations_dashboard
      cleanup_preview = Admin.receipt_analysis_cleanup_preview

      Result.new(
        receipt_analysis: receipt_analysis_summary,
        cleanup: cleanup_summary(cleanup_preview),
        audit: audit_summary,
        contact_requests: contact_requests_summary,
        security: security_summary,
        external_services: ExternalServices.status_snapshot(include_details: true),
        storage: Storage.system_usage_snapshot,
        legal_documents: LegalDocuments::CurrentStatus.call(locale: I18n.locale),
        database_status: Admin.database_status_snapshot,
        system_operations: system_operations_summary(system_dashboard),
        locked_future_operations: system_dashboard.locked_future_operations
      )
    end

    private

    attr_reader :admin_user

    def receipt_analysis_summary
      {
        active_runs_count: ReceiptAnalysisRun.active.count,
        failed_runs_count: ReceiptAnalysisRun.where(status: "failed").count,
        review_needed_receipts_count: Receipt.where(status: "review_needed").count,
        needs_attention_count: needs_attention_relation.count,
        latest_run_at: ReceiptAnalysisRun.order(created_at: :desc).pick(:created_at)
      }
    end

    def cleanup_summary(cleanup_preview)
      {
        stale_dry_run_count: cleanup_preview.stale[:stale_count].to_i,
        expired_dry_run_count: cleanup_preview.retention[:expired_count].to_i,
        stale_cutoff: cleanup_preview.stale[:cutoff],
        retention_cutoff: cleanup_preview.retention[:cutoff]
      }
    end

    def audit_summary
      {
        recent_failed_admin_actions_count: recent_admin_audit_logs.where(outcome: "failed").count,
        recent_retry_actions_count: recent_admin_audit_logs.where(action: RETRY_AUDIT_ACTIONS).count,
        recent_cleanup_execute_count: recent_admin_audit_logs.where(action: CLEANUP_EXECUTE_AUDIT_ACTIONS).count,
        recent_since: RECENT_WINDOW.ago
      }
    end

    def contact_requests_summary
      {
        unresolved_count: ContactRequest.unresolved.count,
        open_count: ContactRequest.where(status: "open").count,
        in_progress_count: ContactRequest.where(status: "in_progress").count,
        security_open_count: ContactRequest.where(status: %w[open in_progress], category: "security").count,
        latest_created_at: ContactRequest.order(created_at: :desc).pick(:created_at)
      }
    end

    def security_summary
      {
        admin_passkey_count: admin_user.passkeys.count,
        open_security_events_count: SecurityEvent.unresolved.count,
        high_security_events_count: SecurityEvent.unresolved.where(severity: %w[high critical]).count,
        recent_security_events_count: SecurityEvent.where(last_seen_at: RECENT_WINDOW.ago..).count
      }
    end

    def system_operations_summary(system_dashboard)
      {
        queues: system_dashboard.queues,
        recurring_dry_run_count: system_dashboard.recurring_tasks.size,
        recurring_tasks: system_dashboard.recurring_tasks
      }
    end

    def needs_attention_relation
      ReceiptAnalysisRun.where(status: "failed").or(
        ReceiptAnalysisRun.where(
          "receipt_analysis_runs.final_result_summary ->> 'receipt_status' IN (?)",
          RECEIPT_ATTENTION_STATUSES
        )
      )
    end

    def recent_admin_audit_logs
      AuditLog.where(actor_kind: "admin", created_at: RECENT_WINDOW.ago..)
    end
  end
end
