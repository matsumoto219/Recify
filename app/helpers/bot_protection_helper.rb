module BotProtectionHelper
  def turnstile_widget_enabled?
    BotProtection.turnstile_enabled? && turnstile_site_key.present?
  end

  def turnstile_site_key
    BotProtection.turnstile_site_key
  end
end
