module Admin
  class PasskeyReauthWindow
    SETTING_KEY = "security.admin_passkey_reauth_window_minutes".freeze
    DEFAULT_DURATION = 5.minutes

    class << self
      def duration
        SystemSettings.limit_for(SETTING_KEY).minutes
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        DEFAULT_DURATION
      end

      def fresh?(reauthentication)
        context = reauthentication.to_h.symbolize_keys

        context[:method] == "passkey" &&
          reauthenticated_at(context).present? &&
          reauthenticated_at(context) >= duration.ago
      rescue ArgumentError, TypeError
        false
      end

      def reauthenticated_at(reauthentication)
        value = reauthentication.to_h.symbolize_keys[:reauthenticated_at]
        value.respond_to?(:>=) ? value : Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
