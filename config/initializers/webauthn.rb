module Recify
  module WebAuthnConfig
    module_function

    def rp_id(env: Rails.env, source: ENV)
      return source.fetch("WEBAUTHN_RP_ID") if production_runtime?(env, source)

      source.fetch("WEBAUTHN_RP_ID", "localhost")
    end

    def allowed_origins(env: Rails.env, source: ENV)
      origins =
        if production_runtime?(env, source)
          source.fetch("WEBAUTHN_ALLOWED_ORIGINS")
        else
          source.fetch("WEBAUTHN_ALLOWED_ORIGINS", "http://localhost:3000")
        end

      origins.split(",").map(&:strip)
    end

    def production_runtime?(env, source)
      env.production? && source["SECRET_KEY_BASE_DUMMY"].blank?
    end
  end
end

WebAuthn.configure do |config|
  config.rp_name = "Recify"
  config.rp_id = Recify::WebAuthnConfig.rp_id
  config.allowed_origins = Recify::WebAuthnConfig.allowed_origins
  config.credential_options_timeout = 120_000
end
