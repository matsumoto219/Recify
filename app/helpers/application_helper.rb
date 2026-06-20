module ApplicationHelper
  CONFIRM_DIALOG_VARIANTS = %i[neutral danger].freeze
  CONFIRM_DIALOG_ICONS = %i[help logout delete security passkey key warning].freeze
  CONFIRM_DIALOG_BACKDROPS = %i[blur plain none].freeze

  def mobile_request?
    ua = request.user_agent.to_s
    ua.match?(/Mobile|iPhone|Android/)
  end

  def home_lp_stylesheet_path
    stylesheet_path = Rails.root.join("public/home_lp.css")
    version = "#{File.mtime(stylesheet_path).to_i}-#{File.size(stylesheet_path)}"

    "/home_lp.css?v=#{version}"
  end

  def auth_page_shell_class
    if dashboard_auth_page?
      "auth-page-shell auth-page-shell-dashboard w-full flex justify-center px-0 py-4 md:py-6 relative overflow-hidden"
    else
      "auth-page-shell auth-page-shell-standalone min-h-screen flex items-center justify-center p-6 md:p-8 relative overflow-hidden"
    end
  end

  def auth_page_show_icon?
    !dashboard_auth_page?
  end

  def confirm_dialog_data(
    message,
    variant: :neutral,
    icon: :help,
    confirm_label: nil,
    title: nil,
    backdrop: nil
  )
    {
      turbo_confirm: message,
      confirm_variant: confirm_dialog_allowed_value(variant, CONFIRM_DIALOG_VARIANTS, :neutral),
      confirm_icon: confirm_dialog_allowed_value(icon, CONFIRM_DIALOG_ICONS, :help),
      confirm_confirm_label: confirm_label.presence,
      confirm_title: title.presence,
      confirm_backdrop: confirm_dialog_allowed_value(backdrop, CONFIRM_DIALOG_BACKDROPS, nil)
    }.compact
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

  private

  def dashboard_auth_page?
    user_signed_in? && !public_layout_page?
  end

  def confirm_dialog_allowed_value(value, allowed_values, fallback)
    return fallback&.to_s if value.blank?

    normalized_value = value.to_sym
    allowed_values.include?(normalized_value) ? normalized_value.to_s : fallback&.to_s
  end
end
