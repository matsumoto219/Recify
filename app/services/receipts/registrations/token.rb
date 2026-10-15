require "digest"

class Receipts::Registrations::Token
  PURPOSE = "receipt_registration_v1".freeze
  KINDS = %w[upload manual].freeze
  KEYS = %w[version user_id kind nonce issued_at expires_at].freeze
  MAX_BYTES = 2_048
  LIFETIME = 24.hours
  Result = Data.define(:state, :kind, :operation_key, :issued_at, :expires_at)
  private_constant :PURPOSE, :KINDS, :KEYS, :MAX_BYTES, :LIFETIME, :Result

  class << self
    def issue(user:, kind:)
      unless valid_user?(user) && KINDS.include?(kind)
        raise ArgumentError, "invalid registration token request"
      end

      issued_at = Time.current.to_i
      verifier.generate(
        {
          "version" => 1,
          "user_id" => user.id,
          "kind" => kind,
          "nonce" => SecureRandom.hex(16),
          "issued_at" => issued_at,
          "expires_at" => issued_at + LIFETIME.to_i
        },
        purpose: PURPOSE
      )
    end

    def verify(user:, token:)
      return rejected("invalid") unless valid_user?(user) && valid_token?(token)

      payload = verifier.verified(token, purpose: PURPOSE)
      return rejected("invalid") unless valid_payload?(payload, user)
      return rejected("expired") if payload.fetch("expires_at") <= Time.current.to_i

      Result.new(
        state: "valid",
        kind: payload.fetch("kind").freeze,
        operation_key: Digest::SHA256.hexdigest(payload.fetch("nonce")).freeze,
        issued_at: Time.at(payload.fetch("issued_at")).utc,
        expires_at: Time.at(payload.fetch("expires_at")).utc
      )
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      rejected("invalid")
    end

    private

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def valid_user?(user)
      user.is_a?(User) && user.persisted? && user.id.is_a?(Integer) && user.id.positive?
    end

    def valid_token?(token)
      token.is_a?(String) && token.bytesize.between?(1, MAX_BYTES) &&
        token.valid_encoding? && token.ascii_only? && /\A[A-Za-z0-9+\/_=.\-]+\z/.match?(token)
    end

    def valid_payload?(payload, user)
      payload.is_a?(Hash) && payload.keys.sort == KEYS.sort &&
        valid_identity_and_lifetime?(payload, user) &&
        payload["nonce"].is_a?(String) && /\A[0-9a-f]{32}\z/.match?(payload["nonce"])
    end

    def valid_identity_and_lifetime?(payload, user)
      payload["version"] == 1 && payload["user_id"] == user.id && KINDS.include?(payload["kind"]) &&
        payload["issued_at"].is_a?(Integer) && payload["expires_at"].is_a?(Integer) &&
        payload["issued_at"].positive? && payload["issued_at"] <= Time.current.to_i &&
        payload["expires_at"] - payload["issued_at"] == LIFETIME.to_i
    end

    def rejected(state)
      Result.new(state:, kind: nil, operation_key: nil, issued_at: nil, expires_at: nil)
    end
  end
end
