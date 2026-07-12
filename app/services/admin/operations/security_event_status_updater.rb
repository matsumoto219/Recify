module Admin
  class Operations::SecurityEventStatusUpdater
    Result = Data.define(:security_event, :updated, :error_code) do
      def initialize(security_event:, updated:, error_code: nil)
        super(security_event:, updated:, error_code:)
      end

      def updated?
        updated == true
      end
    end

    class << self
      def call(security_event:, status:, actor:, request:)
        new(security_event: security_event, status: status, actor: actor, request: request).call
      end
    end

    def initialize(security_event:, status:, actor:, request:)
      @security_event = security_event
      @status = status.to_s
      @actor = actor
      @request = request
    end

    def call
      return Result.new(security_event: security_event, updated: false, error_code: "invalid_status") unless valid_status?

      security_event.with_lock do
        before_state = state_snapshot
        apply_status!
        security_event.save!

        AuditLogs.record_admin_action!(
          actor: actor,
          action: "admin.security_events.#{status}",
          target: security_event,
          target_uid: "security_event:#{security_event.id}",
          reason: nil,
          outcome: "succeeded",
          metadata: audit_metadata,
          before_state: before_state,
          after_state: state_snapshot,
          request: request
        )
      end

      Result.new(security_event: security_event, updated: true)
    rescue ActiveRecord::RecordInvalid
      Result.new(security_event: security_event, updated: false, error_code: "record_invalid")
    end

    private

    attr_reader :security_event, :status, :actor, :request

    def valid_status?
      %w[resolved ignored].include?(status)
    end

    def apply_status!
      now = Time.current

      if status == "resolved"
        security_event.resolved_at = now
        security_event.ignored_at = nil
      else
        security_event.ignored_at = now
        security_event.resolved_at = nil
      end
    end

    def state_snapshot
      {
        resolved_at: security_event.resolved_at&.iso8601,
        ignored_at: security_event.ignored_at&.iso8601
      }
    end

    def audit_metadata
      {
        event_type: security_event.event_type,
        severity: security_event.severity,
        count: security_event.count
      }
    end
  end
end
