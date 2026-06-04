module ContactRequests
  MAX_URL_COUNT = 5
  URL_PATTERN = %r{https?://|www\.}i

  Error = Class.new(StandardError)

  Result = Struct.new(:contact_request, :submitted, :spam, :error_code, keyword_init: true) do
    def success?
      submitted == true
    end

    def spam?
      spam == true
    end
  end

  class << self
    def create(user: nil, params:, request: nil)
      attributes = normalize_attributes(user: user, params: params, request: request)

      return spam_result(attributes) if honeypot_filled?(params)

      contact_request = ContactRequest.new(attributes)
      apply_url_guard(contact_request)

      if contact_request.errors.blank? && contact_request.save
        enqueue_admin_notification(contact_request)
        Result.new(contact_request: contact_request, submitted: true, spam: false)
      else
        Result.new(contact_request: contact_request, submitted: false, spam: false, error_code: "validation_failed")
      end
    end

    def email_digest(email)
      normalized = normalize_email(email)
      OpenSSL::HMAC.hexdigest("SHA256", hmac_secret, normalized)
    end

    def category_options
      ContactRequest::CATEGORIES
    end

    private

    def normalize_attributes(user:, params:, request:)
      email = email_for(user: user, params: params)

      {
        user: user,
        sender_name: normalize_optional_text(params[:sender_name]),
        email: email,
        email_digest: email_digest(email),
        category: params[:category].to_s,
        subject: params[:subject].to_s.strip,
        body: params[:body].to_s.strip,
        status: "open",
        source: source_for(user),
        ip_address: request&.remote_ip,
        user_agent: truncate(request&.user_agent.to_s, 1000),
        request_id: truncate(request&.request_id.to_s, 255)
      }
    end

    def email_for(user:, params:)
      return user.email.to_s.strip.downcase if user.present? && !user.guest?

      normalize_email(params[:email])
    end

    def normalize_email(email)
      email.to_s.strip.downcase
    end

    def normalize_optional_text(value)
      value.to_s.strip.presence
    end

    def source_for(user)
      return "public" if user.blank?
      return "guest" if user.guest?

      "authenticated"
    end

    def honeypot_filled?(params)
      params[:company_name].to_s.strip.present?
    end

    def spam_result(attributes)
      Result.new(
        contact_request: ContactRequest.new(attributes),
        submitted: true,
        spam: true,
        error_code: "honeypot"
      )
    end

    def apply_url_guard(contact_request)
      return if contact_request.body.to_s.scan(URL_PATTERN).size <= MAX_URL_COUNT

      contact_request.errors.add(:body, :too_many_urls)
    end

    def enqueue_admin_notification(contact_request)
      unless ContactRequestMailer.admin_notification_enabled?
        Rails.logger.warn("[ContactRequest] support_notification_email_missing request_uid=#{contact_request.request_uid}")
        return
      end

      ContactRequestMailer.admin_notification(contact_request).deliver_later
    end

    def hmac_secret
      Rails.application.key_generator.generate_key("recify/contact-requests/email", 32)
    end

    def truncate(value, limit)
      value.to_s.first(limit)
    end
  end
end
