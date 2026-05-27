# frozen_string_literal: true

Rails.application.configure do
  encryption_credentials = Rails.application.credentials.dig(:active_record_encryption) || {}

  config.active_record.encryption.primary_key =
    ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].presence ||
    encryption_credentials[:primary_key]

  config.active_record.encryption.deterministic_key =
    ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].presence ||
    encryption_credentials[:deterministic_key]

  config.active_record.encryption.key_derivation_salt =
    ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].presence ||
    encryption_credentials[:key_derivation_salt]

  if Rails.env.development? || Rails.env.test?
    config.active_record.encryption.primary_key ||=
      Rails.application.key_generator.generate_key("recify/active-record-encryption/primary", 32)
    config.active_record.encryption.deterministic_key ||=
      Rails.application.key_generator.generate_key("recify/active-record-encryption/deterministic", 32)
    config.active_record.encryption.key_derivation_salt ||=
      Rails.application.key_generator.generate_key("recify/active-record-encryption/salt", 32)
  end
end
