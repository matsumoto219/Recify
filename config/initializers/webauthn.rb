WebAuthn.configure do |config|
  config.rp_name = "Recify"
  config.rp_id = ENV.fetch("WEBAUTHN_RP_ID", Rails.env.production? ? "recify-app.com" : "localhost")
  config.allowed_origins = ENV.fetch(
    "WEBAUTHN_ALLOWED_ORIGINS",
    Rails.env.production? ? "https://recify-app.com" : "http://localhost:3000"
  ).split(",").map(&:strip)
  config.credential_options_timeout = 120_000
end
