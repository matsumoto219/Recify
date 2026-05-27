require "rqrcode"

module TwoFactor
  class Totp
    ISSUER = "Recify"

    class << self
      def generate_secret
        ROTP::Base32.random
      end

      def provisioning_uri(user:, secret:)
        totp(secret).provisioning_uri(user.email)
      end

      def qr_svg(provisioning_uri:)
        RQRCode::QRCode
          .new(provisioning_uri)
          .as_svg(
            color: "000",
            shape_rendering: "crispEdges",
            module_size: 4,
            standalone: true,
            use_path: true
          )
      end

      def verify_setup(user:, code:)
        credential = user.totp_credential
        raise VerificationError, "totp_credential_missing" if credential.blank?

        accepted_time_step = verify_code!(credential: credential, code: code)
        credential.update!(
          confirmed_at: credential.confirmed_at || Time.current,
          last_used_at: Time.current,
          last_accepted_time_step: accepted_time_step
        )
        credential
      end

      def verify(user:, code:)
        credential = user.totp_credential
        raise VerificationError, "totp_credential_missing" if credential.blank?
        raise VerificationError, "totp_credential_unconfirmed" unless credential.confirmed?

        accepted_time_step = verify_code!(credential: credential, code: code)
        credential.update!(
          last_used_at: Time.current,
          last_accepted_time_step: accepted_time_step
        )
        credential
      end

      private

      def verify_code!(credential:, code:)
        accepted_timestamp = totp(credential.totp_secret).verify(
          normalize_code(code),
          after: accepted_after_timestamp(credential)
        )
        raise VerificationError, "totp_code_invalid" if accepted_timestamp.blank?

        accepted_timestamp / 30
      end

      def totp(secret)
        ROTP::TOTP.new(secret, issuer: ISSUER)
      end

      def accepted_after_timestamp(credential)
        return if credential.last_accepted_time_step.blank?

        credential.last_accepted_time_step * 30
      end

      def normalize_code(code)
        code.to_s.gsub(/\s+/, "")
      end
    end
  end
end
