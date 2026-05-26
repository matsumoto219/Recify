module Admin
  class << self
    def receipt_analysis_runs(**filters)
      ReceiptAnalysisRunsQuery.call(**filters)
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
  end
end
