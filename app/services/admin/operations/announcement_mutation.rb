module Admin
  class Operations::AnnouncementMutation
    AUDIT_LINK_LIMIT = 3

    Result = Data.define(:announcement, :saved) do
      def saved?
        saved == true
      end
    end

    class << self
      def create(attributes:, actor:, request:, remove_image_requested: false, uploaded_image: nil, security_context: {})
        new(
          actor: actor,
          request: request,
          remove_image_requested: remove_image_requested,
          uploaded_image: uploaded_image,
          security_context: security_context
        ).create(attributes: attributes)
      end

      def update(announcement:, attributes:, actor:, request:, remove_image_requested: false, uploaded_image: nil, security_context: {})
        new(
          actor: actor,
          request: request,
          remove_image_requested: remove_image_requested,
          uploaded_image: uploaded_image,
          security_context: security_context
        ).update(announcement: announcement, attributes: attributes)
      end

      def publish(announcement:, actor:, request:)
        new(actor: actor, request: request).publish(announcement: announcement)
      end

      def archive(announcement:, actor:, request:)
        new(actor: actor, request: request).archive(announcement: announcement)
      end
    end

    def initialize(actor:, request:, remove_image_requested: false, uploaded_image: nil, security_context: {})
      @actor = actor
      @request = request
      @remove_image_requested = remove_image_requested
      @uploaded_image = uploaded_image
      @security_context = security_context
    end

    def create(attributes:)
      announcement = Announcement.new(attributes)
      announcement.status = "draft"
      announcement.created_by = actor
      announcement.updated_by = actor

      saved = persist(announcement, action: "announcement.create", before_state: {})
      finalize_input_mutation(announcement, saved: saved)
    end

    def update(announcement:, attributes:)
      before_state = audit_state(announcement)
      announcement.assign_attributes(attributes)
      announcement.status = "draft"
      announcement.updated_by = actor

      saved = persist(announcement, action: "announcement.update", before_state: before_state)
      finalize_input_mutation(announcement, saved: saved)
    end

    def publish(announcement:)
      before_state = audit_state(announcement)
      announcement.status = "published"
      announcement.published_at ||= Time.current
      announcement.updated_by = actor

      saved = persist(announcement, action: "announcement.publish", before_state: before_state)
      Result.new(announcement: announcement, saved: saved)
    end

    def archive(announcement:)
      before_state = audit_state(announcement)
      announcement.status = "archived"
      announcement.updated_by = actor

      saved = persist(announcement, action: "announcement.archive", before_state: before_state)
      Result.new(announcement: announcement, saved: saved)
    end

    private

    attr_reader :actor, :request, :remove_image_requested, :uploaded_image, :security_context

    def finalize_input_mutation(announcement, saved:)
      if saved
        purge_image_if_requested!(announcement)
      else
        record_invalid_upload_security_event(announcement.errors)
      end

      Result.new(announcement: announcement, saved: saved)
    end

    def persist(announcement, action:, before_state:)
      saved = false

      Announcement.transaction do
        saved = announcement.save
        record_audit!(
          announcement,
          action: action,
          before_state: before_state,
          after_state: audit_state(announcement)
        ) if saved
      end

      saved
    end

    def record_audit!(announcement, action:, before_state:, after_state:)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: action,
        target: announcement,
        target_uid: announcement.public_id,
        outcome: "succeeded",
        request: request,
        metadata: audit_metadata(announcement),
        before_state: before_state,
        after_state: after_state
      )
    end

    def audit_state(announcement)
      {
        status: announcement.status,
        kind: announcement.kind,
        pinned: announcement.pinned,
        priority: announcement.priority,
        starts_at: announcement.starts_at,
        ends_at: announcement.ends_at,
        published_at: announcement.published_at
      }
    end

    def audit_metadata(announcement)
      {
        public_id: announcement.public_id,
        title: announcement.title,
        kind: announcement.kind,
        starts_at: announcement.starts_at,
        ends_at: announcement.ends_at,
        pinned: announcement.pinned,
        priority: announcement.priority,
        published_at: announcement.published_at,
        **audit_image_metadata(announcement),
        links: audit_links(announcement)
      }
    end

    def audit_image_metadata(announcement)
      image_attached = announcement.image.attached? && announcement.image.blob&.persisted?
      metadata = {
        image_attached: image_attached,
        image_alt_text_present: announcement.image_alt_text.present?
      }
      return metadata unless image_attached

      metadata.merge(
        image_filename: announcement.image.filename.to_s,
        image_content_type: announcement.image.blob.content_type,
        image_byte_size: announcement.image.blob.byte_size
      )
    end

    def audit_links(announcement)
      announcement.announcement_links.sort_by(&:position).first(AUDIT_LINK_LIMIT).map do |link|
        {
          position: link.position,
          label: link.label,
          external: link.external?,
          url: sanitized_audit_url(link.url)
        }
      end
    end

    def sanitized_audit_url(value)
      url = value.to_s
      uri = URI.parse(url)

      if url.start_with?("/")
        uri.path.presence || "/"
      else
        port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
        path = uri.path.presence || "/"
        "#{uri.scheme}://#{uri.host}#{port}#{path}"
      end
    rescue URI::InvalidURIError
      "[invalid]"
    end

    def purge_image_if_requested!(announcement)
      return unless remove_image_requested
      return if uploaded_image.present?
      return unless announcement.image.attached?

      Storage.purge_attachment(announcement.image)
      announcement.update_columns(image_alt_text: nil, updated_at: Time.current)
    end

    def record_invalid_upload_security_event(errors)
      reason = image_security_event_reason(errors)
      return if uploaded_image.blank? || reason.blank?

      SecurityEvents.record_invalid_upload!(
        request: request,
        actor_user: actor,
        file: uploaded_image,
        reason: reason,
        field_name: "announcement.image",
        metadata: {
          controller: security_context[:controller],
          action: security_context[:action],
          validation_errors: errors.full_messages_for(:image).first(3)
        }
      )
    end

    def image_security_event_reason(errors)
      return "invalid_content_type" if errors.of_kind?(:image, :invalid_content_type)
      return "file_too_large" if errors.of_kind?(:image, :file_too_large)
      return "image_too_small" if errors.of_kind?(:image, :image_too_small)

      "image_too_large" if errors.of_kind?(:image, :image_too_large)
    end
  end
end
