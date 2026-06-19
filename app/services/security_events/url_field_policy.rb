module SecurityEvents
  class UrlFieldPolicy
    ANNOUNCEMENT_LINK_URL_FIELD_PATTERN = /\Aannouncement\.announcement_links_attributes\.\d+\.url\z/
    WRITE_METHODS = %w[POST PATCH PUT].freeze

    URL_FIELD_PATTERN = /
      (?:redirect(?:_to|url)?|return(?:_to|url)?|next|callback(?:_url|url)?|
      webhook(?:_url|url)?|url|uri|target|continue)
    /ix
    REDIRECT_FIELD_PATTERN = /(?:redirect(?:_to|url)?|return(?:_to|url)?|next|target|continue)/i
    CALLBACK_FIELD_PATTERN = /(?:callback(?:_url|url)?|webhook(?:_url|url)?|uri)/i

    class << self
      def for_request(request)
        new(
          path: request&.path,
          method: request&.request_method
        )
      end
    end

    def initialize(path: nil, method: nil)
      @path = path.to_s
      @method = method.to_s.upcase
    end

    def url_field?(field_name)
      URL_FIELD_PATTERN.match?(normalized_field_name(field_name))
    end

    def open_redirect_candidate?(field_name, value)
      return false unless url_field?(field_name)
      return false if link_storage_field?(field_name) && safe_link_storage_url?(value)

      redirect_field?(field_name) || callback_field?(field_name) || unknown_url_field?(field_name)
    end

    def link_storage_field?(field_name)
      admin_announcements_write_request? &&
        ANNOUNCEMENT_LINK_URL_FIELD_PATTERN.match?(field_name.to_s)
    end

    private

    attr_reader :path, :method

    def normalized_field_name(field_name)
      field_name.to_s.delete(".[]").underscore
    end

    def redirect_field?(field_name)
      REDIRECT_FIELD_PATTERN.match?(normalized_field_name(field_name))
    end

    def callback_field?(field_name)
      CALLBACK_FIELD_PATTERN.match?(normalized_field_name(field_name))
    end

    def unknown_url_field?(field_name)
      url_field?(field_name) && !link_storage_field?(field_name)
    end

    def safe_link_storage_url?(value)
      AnnouncementLink.safe_external_url?(value.to_s)
    end

    def admin_announcements_write_request?
      path.start_with?("/admin/announcements") && WRITE_METHODS.include?(method)
    end
  end
end
