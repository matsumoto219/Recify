require "rqrcode"

module TwoFactor
  class Totp
    ISSUER = "Recify"

    class << self
      def prepare_setup(user:)
        secret = generate_secret
        provisioning_uri = self.provisioning_uri(user: user, secret: secret)

        SetupMaterial.new(
          secret: secret,
          provisioning_uri: provisioning_uri,
          qr_svg: qr_svg(provisioning_uri: provisioning_uri)
        )
      end

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
            use_path: true,
            viewbox: true,
            svg_attributes: {
              width: "100%",
              height: "100%"
            }
          )
      end

      def confirm_setup(user:, secret:, code:)
        raise VerificationError, "totp_secret_missing" if secret.blank?

        credential = nil
        recovery_codes = []
        TotpCredential.transaction do
          credential = verify_setup(user: user, code: code, secret: secret)
          recovery_codes = RecoveryCodes.regenerate_for(user: user)
        end

        SetupConfirmation.new(credential: credential, recovery_codes: recovery_codes)
      end

      def verify_setup(user:, code:, secret: nil)
        credential = user.totp_credential || user.build_totp_credential
        secret ||= credential.totp_secret
        raise VerificationError, "totp_credential_missing" if secret.blank?

        accepted_time_step = verify_code_for_secret!(
          secret: secret,
          code: code,
          after_time_step: credential.last_accepted_time_step
        )
        credential.assign_attributes(
          totp_secret: secret,
          confirmed_at: credential.confirmed_at || Time.current,
          last_used_at: Time.current,
          last_accepted_time_step: accepted_time_step
        )
        credential.save!
        credential
      end

      def verify(user:, code:)
        credential = user.totp_credential
        raise VerificationError, "totp_credential_missing" if credential.blank?
        raise VerificationError, "totp_credential_unconfirmed" unless credential.confirmed?

        accepted_time_step = verify_code_for_secret!(
          secret: credential.totp_secret,
          code: code,
          after_time_step: credential.last_accepted_time_step
        )
        credential.update!(
          last_used_at: Time.current,
          last_accepted_time_step: accepted_time_step
        )
        credential
      end

      def disable_for(user:)
        TotpCredential.transaction do
          user.totp_credential&.destroy!
          user.recovery_codes.delete_all
        end
      end

      private

      def verify_code_for_secret!(secret:, code:, after_time_step:)
        accepted_timestamp = totp(secret).verify(
          normalize_code(code),
          after: accepted_after_timestamp(after_time_step)
        )
        raise VerificationError, "totp_code_invalid" if accepted_timestamp.blank?

        accepted_timestamp / 30
      end

      def totp(secret)
        ROTP::TOTP.new(secret, issuer: ISSUER)
      end

      def accepted_after_timestamp(time_step)
        return if time_step.blank?

        time_step * 30
      end

      def normalize_code(code)
        code.to_s.gsub(/\s+/, "")
      end
    end
  end
end
