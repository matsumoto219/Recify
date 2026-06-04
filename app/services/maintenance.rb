module Maintenance
  MODE_KEY = "maintenance.mode"
  TITLE_KEY = "maintenance.title"
  BODY_KEY = "maintenance.body"

  MODE_OFF = "off"
  MODE_LOGIN_RESTRICTED = "login_restricted"
  MODES = [ MODE_OFF, MODE_LOGIN_RESTRICTED ].freeze

  class << self
    def mode(user: nil)
      normalize_mode(SystemSettings.value_for(MODE_KEY, user: user))
    end

    def off?(user: nil)
      mode(user: user) == MODE_OFF
    end

    def active?(user: nil)
      !off?(user: user)
    end

    def login_restricted?(user: nil)
      mode(user: user) == MODE_LOGIN_RESTRICTED
    end

    def admin_bypass_user?(user)
      user.present? && user.admin? && user.active_for_authentication? && !user.guest?
    end

    def login_allowed_for?(user)
      !login_restricted? || admin_bypass_user?(user)
    end

    def title(user: nil)
      configured_text(TITLE_KEY, fallback_key: "shared.maintenance_mode.title", user: user)
    end

    def body(user: nil)
      configured_text(BODY_KEY, fallback_key: "shared.maintenance_mode.body", user: user)
    end

    private

    def normalize_mode(value)
      mode = value.to_s
      MODES.include?(mode) ? mode : MODE_OFF
    end

    def configured_text(key, fallback_key:, user:)
      SystemSettings.value_for(key, user: user).to_s.presence || I18n.t(fallback_key)
    end
  end
end
