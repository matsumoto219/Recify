module Admin
  class ReceiptAnalysisCleanupInvalidParameter < StandardError; end

  class << self
    def receipt_analysis_runs(**filters)
      ReceiptAnalysisRunsQuery.call(**filters)
    end

    def receipt_analysis_run_filter_options
      ReceiptAnalysisRunsQuery.filter_options
    end

    def receipts(**filters)
      ReceiptsQuery.call(**filters)
    end

    def receipt(public_id:)
      ReceiptsQuery.find(public_id: public_id)
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

    def security_events(**filters)
      SecurityEventsQuery.call(**filters)
    end

    def security_event_filter_options
      SecurityEventsQuery.filter_options
    end

    def security_event(id:)
      SecurityEventsQuery.find(id: id)
    end

    def ip_blocks(**filters)
      IpBlocksQuery.call(**filters)
    end

    def ip_block_filter_options
      IpBlocksQuery.filter_options
    end

    def ip_block(id:)
      IpBlocksQuery.find(id: id)
    end

    def ip_actions(**filters)
      IpActionsQuery.call(**filters)
    end

    def contact_requests(**filters)
      ContactRequestsQuery.call(**filters)
    end

    def announcements(**filters)
      AnnouncementsQuery.call(**filters)
    end

    def announcement_filter_options
      AnnouncementsQuery.filter_options
    end

    def contact_request_filter_options
      ContactRequestsQuery.filter_options
    end

    def contact_request(id:)
      ContactRequestsQuery.find(id: id)
    end

    def users(**filters)
      UsersQuery.call(**filters)
    end

    def user(id:)
      UsersQuery.find(id: id)
    end

    def legal_acceptance_status(user_id:, locale: I18n.locale)
      LegalAcceptanceStatus.call(user_id: user_id, locale: locale)
    end

    def receipt_analysis_cleanup_preview(**params)
      ReceiptAnalysisCleanupPreview.call(**params)
    end

    def system_operations_dashboard
      SystemOperationsDashboard.call
    end

    def database_status_snapshot
      DatabaseStatusSnapshot.call
    end

    def passkey_reauth_window_duration
      PasskeyReauthWindow.duration
    end

    def passkey_reauth_fresh?(reauthentication, user:)
      PasskeyReauthWindow.fresh?(reauthentication, user: user)
    end

    def passkey_reauthenticated_at(reauthentication)
      PasskeyReauthWindow.reauthenticated_at(reauthentication)
    end

    def system_settings(**filters)
      SystemSettingsQuery.call(**filters)
    end

    def system_setting(key:)
      SystemSettingsQuery.find(key:)
    end
  end
end
