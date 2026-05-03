module ApplicationHelper
  def mobile_request?
    ua = request.user_agent.to_s
    ua.match?(/Mobile|iPhone|Android/)
  end

  def masked_email_with_domain(
    email,
    local_max_length: 8,
    domain_max_length: nil,
    local_max_length_mobile: nil,
    domain_max_length_mobile: nil
  )
    email_text = email.to_s
    local_part, domain = email_text.split("@", 2)

    return email_text if local_part.blank? || domain.blank?

    # local part falls back between PC/mobile settings; domain is controlled independently per device.
    if mobile_request?
      effective_local_length = local_max_length_mobile || local_max_length
      effective_domain_length = domain_max_length_mobile
    else
      effective_local_length = local_max_length || local_max_length_mobile
      effective_domain_length = domain_max_length
    end

    # local part trimming
    if effective_local_length.present? && local_part.length > effective_local_length
      local_part = "#{local_part.first(effective_local_length)}..."
    end

    # domain trimming
    if effective_domain_length.present? && domain.length > effective_domain_length
      domain = "#{domain.first(effective_domain_length)}..."
    end

    "#{local_part}@#{domain}"
  end
end
