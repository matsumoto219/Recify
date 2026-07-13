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

      def fresh?(reauthentication, user:)
        context = reauthentication.to_h.symbolize_keys
        authenticated_at = reauthenticated_at(context)
        issued_expires_at = expires_at(context)
        current_expires_at = authenticated_at + duration if authenticated_at
        effective_expires_at = [
          issued_expires_at || current_expires_at,
          current_expires_at
        ].compact.min

        context[:method] == "passkey" &&
          authenticated_at.present? &&
          authenticated_at <= Time.current &&
          effective_expires_at.present? &&
          effective_expires_at > Time.current &&
          user_matches?(context, user, issued_expires_at: issued_expires_at)
      rescue ArgumentError, TypeError
        false
      end

      def reauthenticated_at(reauthentication)
        value = reauthentication.to_h.symbolize_keys[:reauthenticated_at]
        value.respond_to?(:>=) ? value : Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      private

      def expires_at(context)
        value = context[:expires_at]
        return value if value.respond_to?(:>)

        Time.zone.parse(value.to_s) if value.present?
      rescue ArgumentError, TypeError
        nil
      end

      def user_matches?(context, user, issued_expires_at:)
        return false unless user
        return false unless issued_expires_at
        return false unless context.key?(:user_id) && context.key?(:session_version)

        context[:user_id].to_i == user.id.to_i &&
          context[:session_version].to_i == user.session_version.to_i
      end
    end
  end
end
