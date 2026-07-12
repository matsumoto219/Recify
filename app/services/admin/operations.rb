module Admin
  module Operations
    class << self
      def update_contact_request_status(contact_request:, status:, actor:, request:)
        Admin::ContactRequestStatusUpdater.call(
          contact_request: contact_request,
          status: status,
          actor: actor,
          request: request
        )
      end

      def update_security_event_status(security_event:, status:, actor:, request:)
        Admin::SecurityEventStatusUpdater.call(
          security_event: security_event,
          status: status,
          actor: actor,
          request: request
        )
      end
    end
  end
end
