module Admin
  module Operations
    class << self
      def create_announcement(attributes:, actor:, request:, remove_image_requested:, uploaded_image:, security_context:)
        AnnouncementMutation.create(
          attributes: attributes,
          actor: actor,
          request: request,
          remove_image_requested: remove_image_requested,
          uploaded_image: uploaded_image,
          security_context: security_context
        )
      end

      def update_announcement(announcement:, attributes:, actor:, request:, remove_image_requested:, uploaded_image:, security_context:)
        AnnouncementMutation.update(
          announcement: announcement,
          attributes: attributes,
          actor: actor,
          request: request,
          remove_image_requested: remove_image_requested,
          uploaded_image: uploaded_image,
          security_context: security_context
        )
      end

      def publish_announcement(announcement:, actor:, request:)
        AnnouncementMutation.publish(announcement: announcement, actor: actor, request: request)
      end

      def archive_announcement(announcement:, actor:, request:)
        AnnouncementMutation.archive(announcement: announcement, actor: actor, request: request)
      end

      def update_contact_request_status(contact_request:, status:, actor:, request:)
        ContactRequestStatusUpdater.call(
          contact_request: contact_request,
          status: status,
          actor: actor,
          request: request
        )
      end

      def update_security_event_status(security_event:, status:, actor:, request:)
        SecurityEventStatusUpdater.call(
          security_event: security_event,
          status: status,
          actor: actor,
          request: request
        )
      end
    end
  end
end
