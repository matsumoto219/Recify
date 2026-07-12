module Admin
  class Operations::ContactRequestStatusUpdater
    Result = Data.define(:contact_request, :updated, :error_code) do
      def initialize(contact_request:, updated:, error_code: nil)
        super(contact_request:, updated:, error_code:)
      end

      def success?
        updated == true
      end
    end

    class << self
      def call(contact_request:, status:, actor:, request:)
        new(contact_request: contact_request, status: status, actor: actor, request: request).call
      end
    end

    def initialize(contact_request:, status:, actor:, request:)
      @contact_request = contact_request
      @status = status.to_s
      @actor = actor
      @request = request
    end

    def call
      return Result.new(contact_request: contact_request, updated: false, error_code: "invalid_status") unless valid_status?

      old_status = contact_request.status

      ActiveRecord::Base.transaction do
        contact_request.update!(
          status: status,
          handled_by_user: actor,
          handled_at: Time.current
        )

        AuditLogs.record_admin_action!(
          actor: actor,
          action: "admin.contact_requests.status_update",
          target: contact_request,
          target_uid: contact_request.request_uid,
          outcome: "succeeded",
          metadata: audit_metadata(old_status: old_status, new_status: status),
          before_state: { status: old_status },
          after_state: { status: status },
          request: request
        )
      end

      Result.new(contact_request: contact_request, updated: true)
    rescue ActiveRecord::RecordInvalid
      Result.new(contact_request: contact_request, updated: false, error_code: "validation_failed")
    end

    private

    attr_reader :contact_request, :status, :actor, :request

    def valid_status?
      ContactRequest::STATUSES.include?(status)
    end

    def audit_metadata(old_status:, new_status:)
      {
        request_uid: contact_request.request_uid,
        old_status: old_status,
        new_status: new_status,
        category: contact_request.category,
        user_id: contact_request.user_id,
        email_digest: contact_request.email_digest
      }
    end
  end
end
