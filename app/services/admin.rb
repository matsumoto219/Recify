module Admin
  class << self
    def receipt_analysis_runs(**filters)
      ReceiptAnalysisRunsQuery.call(**filters)
    end

    def audit_logs(**filters)
      AuditLogsQuery.call(**filters)
    end
  end
end
