module Admin
  class << self
    def receipt_analysis_runs(**filters)
      ReceiptAnalysisRunsQuery.call(**filters)
    end

    def receipt_analysis_run_filter_options
      ReceiptAnalysisRunsQuery.filter_options
    end

    def dashboard(admin_user:)
      Dashboard.call(admin_user: admin_user)
    end

    def audit_logs(**filters)
      AuditLogsQuery.call(**filters)
    end

    def audit_log_filter_options
      AuditLogsQuery.filter_options
    end

    def contact_requests(**filters)
      ContactRequestsQuery.call(**filters)
    end

    def contact_request_filter_options
      ContactRequestsQuery.filter_options
    end

    def contact_request(id:)
      ContactRequestsQuery.find(id: id)
    end

    def update_contact_request_status(contact_request:, status:, actor:, request:)
      ContactRequestStatusUpdater.call(
        contact_request: contact_request,
        status: status,
        actor: actor,
        request: request
      )
    end

    def users(**filters)
      UsersQuery.call(**filters)
    end

    def user(id:)
      UsersQuery.find(id: id)
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
