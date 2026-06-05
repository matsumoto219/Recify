module ContactRequests
  class Anonymizer
    REDACTED_SUBJECT = "[redacted]".freeze
    REDACTED_BODY = "[redacted by retention policy]".freeze
    REDACTED_EMAIL_DOMAIN = "example.invalid".freeze

    class << self
      def call(contact_request)
        new(contact_request).call
      end

      def redacted_email_for(contact_request)
        request_uid = contact_request.respond_to?(:request_uid) ? contact_request.request_uid : contact_request.to_s
        "redacted+#{request_uid}@#{REDACTED_EMAIL_DOMAIN}"
      end

      def anonymized?(contact_request)
        contact_request.sender_name.blank? &&
          contact_request.email == redacted_email_for(contact_request) &&
          contact_request.subject == REDACTED_SUBJECT &&
          contact_request.body == REDACTED_BODY &&
          contact_request.ip_address.blank? &&
          contact_request.user_agent.blank? &&
          contact_request.request_id.blank?
      end
    end

    def initialize(contact_request)
      @contact_request = contact_request
    end

    def call
      return contact_request if self.class.anonymized?(contact_request)

      contact_request.update!(
        sender_name: nil,
        email: self.class.redacted_email_for(contact_request),
        subject: REDACTED_SUBJECT,
        body: REDACTED_BODY,
        ip_address: nil,
        user_agent: nil,
        request_id: nil
      )

      contact_request
    end

    private

    attr_reader :contact_request
  end
end
