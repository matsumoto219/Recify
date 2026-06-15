# frozen_string_literal: true

class ProductionEnvValidator
  ValidationError = Class.new(StandardError)

  Result = Struct.new(:missing_keys, keyword_init: true) do
    def success?
      missing_keys.empty?
    end
  end

  ALWAYS_REQUIRED_ENV = %w[
    RAILS_MASTER_KEY
    RECIFY_DATABASE_PASSWORD
    WEBAUTHN_RP_ID
    WEBAUTHN_ALLOWED_ORIGINS
    SUPPORT_NOTIFICATION_EMAIL
  ].freeze

  ENCRYPTION_REQUIRED = {
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => :primary_key,
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => :deterministic_key,
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => :key_derivation_salt
  }.freeze

  class << self
    def validate!(...)
      new(...).validate!
    end

    def call(...)
      new(...).call
    end

    def boot_validate!
      validate!(strict: Rails.env.production?)
    end
  end

  def initialize(
    env: ENV,
    rails_config: Rails.application.config,
    strict: Rails.env.production?
  )
    @env = env
    @rails_config = rails_config
    @strict = strict
  end

  def validate!
    result = call
    return result if result.success? || !strict

    raise ValidationError, error_message(result.missing_keys)
  end

  def call
    Result.new(missing_keys: missing_keys.uniq.sort)
  end

  private

  attr_reader :env, :rails_config, :strict

  def missing_keys
    return [] unless strict

    missing = ALWAYS_REQUIRED_ENV.reject { |key| present_env?(key) }
    missing + missing_encryption_keys
  end

  def missing_encryption_keys
    encryption_config = rails_config.active_record.encryption

    ENCRYPTION_REQUIRED.filter_map do |key, config_method|
      key if blank_value?(encryption_config.public_send(config_method))
    end
  end

  def present_env?(key)
    env[key].to_s.strip.present?
  end

  def blank_value?(value)
    value.to_s.strip.blank?
  end

  def error_message(keys)
    "Missing required production environment configuration: #{keys.join(', ')}"
  end
end
