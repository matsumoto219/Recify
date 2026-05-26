module Admin
  class << self
    def receipt_analysis_runs(**filters)
      ReceiptAnalysisRunsQuery.call(**filters)
    end

    def dashboard(admin_user:)
      Dashboard.call(admin_user: admin_user)
    end

    def audit_logs(**filters)
      AuditLogsQuery.call(**filters)
    end

    def receipt_analysis_cleanup_preview(**params)
      ReceiptAnalysisCleanupPreview.call(**params)
    end

    def system_operations_dashboard
      SystemOperationsDashboard.call
    end

    def system_settings(**filters)
      SystemSettingsQuery.call(**filters)
    end

    def system_setting(key:)
      SystemSettingsQuery.find(key:)
    end
  end
end
