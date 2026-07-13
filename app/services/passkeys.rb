require "openssl"

module Passkeys
  AUTHENTICATION_CHALLENGE_REPLAY_TTL = 10.minutes
  private_constant :AUTHENTICATION_CHALLENGE_REPLAY_TTL
  VerificationResult = Struct.new(:passkey, :user, :credential, keyword_init: true)
  AuthenticationError = Class.new(StandardError)

  class << self
    def registration_limit
      Passkey::MAX_PER_USER
    end

    def count_for(user)
      return 0 if user.blank?

      user.passkeys.count
    end

    def remaining_slots_for(user)
      return 0 if registration_limit_reached?(user)

      [ registration_limit - count_for(user), 0 ].max
    end

    def registration_limit_reached?(user)
      return true if user.blank?
      return true if user.guest?

      count_for(user) >= registration_limit
    end

    def registration_options(user:)
      WebAuthn::Credential.options_for_create(
        user: webauthn_user_entity(user),
        exclude: user.passkeys.pluck(:credential_id),
        authenticator_selection: {
          user_verification: "required",
          resident_key: "required",
          require_resident_key: true
        }
      )
    end

    def verify_registration(user:, credential:, challenge:, label: nil)
      webauthn_credential = WebAuthn::Credential.from_create(credential)
      webauthn_credential.verify(challenge, user_verification: true)

      user.with_lock do
        user.passkeys.create!(
          credential_id: webauthn_credential.id,
          public_key: webauthn_credential.public_key,
          sign_count: webauthn_credential.sign_count || 0,
          label: label,
          transports: credential.dig("response", "transports") || [],
          backup_eligible: webauthn_credential.backup_eligible? || false,
          backed_up: webauthn_credential.backed_up? || false
        )
      end
    end

    def authentication_options(user:)
      WebAuthn::Credential.options_for_get(
        allow: user.passkeys.pluck(:credential_id),
        user_verification: "required"
      )
    end

    def discoverable_authentication_options
      WebAuthn::Credential.options_for_get(user_verification: "required")
    end

    def verify_authentication(credential:, challenge:, user: nil)
      webauthn_credential = WebAuthn::Credential.from_get(credential)
      passkey = Passkey.find_by!(credential_id: webauthn_credential.id)

      passkey.with_lock do
        raise ActiveRecord::RecordNotFound if user.present? && passkey.user_id != user.id

        webauthn_credential.verify(
          challenge,
          public_key: passkey.public_key,
          sign_count: passkey.sign_count,
          user_verification: true
        )
        consume_authentication_challenge!(challenge)

        yield passkey.user if block_given?

        update_authentication_state(passkey, webauthn_credential)

        VerificationResult.new(passkey: passkey, user: passkey.user, credential: webauthn_credential)
      end
    end

    def verify_discoverable_authentication(credential:, challenge:)
      webauthn_credential = WebAuthn::Credential.from_get(credential)
      passkey = Passkey.includes(:user).find_by!(credential_id: webauthn_credential.id)

      passkey.with_lock do
        webauthn_credential.verify(
          challenge,
          public_key: passkey.public_key,
          sign_count: passkey.sign_count,
          user_verification: true
        )

        user = passkey.user
        raise AuthenticationError, "user_handle_missing" if webauthn_credential.user_handle.blank?
        raise AuthenticationError, "user_handle_mismatch" unless ActiveSupport::SecurityUtils.secure_compare(
          webauthn_credential.user_handle,
          user.webauthn_id.to_s
        )

        consume_authentication_challenge!(challenge)
        yield user if block_given?

        update_authentication_state(passkey, webauthn_credential)

        VerificationResult.new(passkey: passkey, user: user, credential: webauthn_credential)
      end
    end

    def reauthentication_options(user:)
      authentication_options(user: user)
    end

    def verify_reauthentication(user:, credential:, challenge:, &block)
      verify_authentication(credential: credential, challenge: challenge, user: user, &block)
    end

    def step_up_options(user:)
      reauthentication_options(user: user)
    end

    def verify_step_up(user:, credential:, challenge:, &block)
      verify_reauthentication(user: user, credential: credential, challenge: challenge, &block)
    end

    private

    def consume_authentication_challenge!(challenge)
      challenge_digest = OpenSSL::Digest::SHA256.hexdigest(challenge.to_s)
      consumed = Rails.cache.write(
        "passkeys/authentication_challenge/#{challenge_digest}",
        true,
        expires_in: AUTHENTICATION_CHALLENGE_REPLAY_TTL,
        unless_exist: true
      )
      raise AuthenticationError, "authentication_challenge_replayed" unless consumed
    end

    def update_authentication_state(passkey, webauthn_credential)
      passkey.update!(
        sign_count: webauthn_credential.sign_count || passkey.sign_count,
        last_used_at: Time.current,
        backup_eligible: webauthn_credential.backup_eligible? || false,
        backed_up: webauthn_credential.backed_up? || false
      )
    end

    def webauthn_user_entity(user)
      {
        id: user.ensure_webauthn_id!,
        name: user.email,
        display_name: user.display_name
      }
    end
  end
end
