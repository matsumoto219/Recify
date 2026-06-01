module Settings
  class IndexPresenter
    def initialize(user:, view_context:)
      @user = user
      @view_context = view_context
    end

    def guest?
      user.guest?
    end

    def user_status_label
      guest? ? t("settings.index.user.guest") : t("settings.index.user.registered")
    end

    def user_name_label
      guest? ? user.display_name : user.name.presence || t("settings.index.user.name_missing")
    end

    def user_email_label
      return user.display_email if guest?

      view_context.masked_email_with_domain(
        user.email,
        local_max_length: 10,
        local_max_length_mobile: 6,
        domain_max_length_mobile: 14
      )
    end

    def totp_state
      user.totp_credential&.confirmed? ? :active : :inactive
    end

    def passkey_state
      user.passkeys.exists? ? :active : :inactive
    end

    def storage_usage
      user.storage_usage
    end

    def theme_options
      [
        { label: t("settings.index.appearance.theme_options.system"), value: "system", icon: "brightness_auto" },
        { label: t("settings.index.appearance.theme_options.light"), value: "light", icon: "light_mode" },
        { label: t("settings.index.appearance.theme_options.dark"), value: "dark", icon: "dark_mode" }
      ]
    end

    def rounding_mode_options
      [
        { label: t("settings.index.calculation.rounding_options.floor"), value: "floor" },
        { label: t("settings.index.calculation.rounding_options.round"), value: "round" },
        { label: t("settings.index.calculation.rounding_options.ceil"), value: "ceil" }
      ]
    end

    private

    attr_reader :user, :view_context

    def t(key)
      I18n.t(key)
    end
  end
end
