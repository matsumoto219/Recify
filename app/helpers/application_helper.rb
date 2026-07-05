module ApplicationHelper
  CONFIRM_DIALOG_VARIANTS = %i[neutral danger].freeze
  CONFIRM_DIALOG_ICONS = %i[help logout delete security passkey key warning].freeze
  CONFIRM_DIALOG_BACKDROPS = %i[blur plain none].freeze

  def home_lp_stylesheet_path
    stylesheet_path = Rails.root.join("public/home_lp.css")
    version = "#{File.mtime(stylesheet_path).to_i}-#{File.size(stylesheet_path)}"

    "/home_lp.css?v=#{version}"
  end

  def auth_page_shell_class
    if dashboard_auth_page?
      "auth-page-shell auth-page-shell-dashboard w-full flex justify-center px-0 py-4 md:py-6 relative overflow-hidden"
    else
      "auth-page-shell auth-page-shell-standalone min-h-screen w-full flex items-start justify-center px-6 pb-8 pt-10 md:px-8 md:pb-10 md:pt-14 lg:pt-16 relative overflow-hidden"
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

  def email_display_parts(email)
    email_text = email.to_s
    local_part, domain = email_text.split("@", 2)

    return { text: email_text, local_part: email_text, domain: nil } if local_part.blank? || domain.blank?

    { text: email_text, local_part: local_part, domain: domain }
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
