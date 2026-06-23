# frozen_string_literal: true

require_relative "production_legal_documents_validator"
require_relative "production_runtime_config"

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
    DB_HOST
    APP_HOST
    WEBAUTHN_RP_ID
    WEBAUTHN_ALLOWED_ORIGINS
    SUPPORT_NOTIFICATION_EMAIL
  ].freeze

  ENCRYPTION_REQUIRED = {
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => :primary_key,
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => :deterministic_key,
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => :key_derivation_salt
  }.freeze

  OCR_ENABLED_ENV_KEY = "RECEIPT_OCR_ENABLED"
  AI_ENABLED_ENV_KEY = "RECEIPT_AI_ENABLED"

  OCR_REQUIRED_ENV = %w[
    AZURE_OCR_ENDPOINT
    AZURE_OCR_API_KEY
  ].freeze

  AI_REQUIRED_ENV = %w[
    OPENAI_API_KEY
    OPENAI_AI_MODEL
  ].freeze

  TURNSTILE_REQUIRED_ENV = %w[
    TURNSTILE_SITE_KEY
    TURNSTILE_SECRET_KEY
  ].freeze

  PLACEHOLDER_VALUES = %w[
    example.com
    from@example.com
    please-change-me-at-config-initializers-devise@example.com
  ].freeze

  class << self
    def validate!(...)
      new(...).validate!
    end

    def call(...)
      new(...).call
    end

    def boot_validate!
      return if ENV["SECRET_KEY_BASE_DUMMY"].present?

      validate!(strict: Rails.env.production?)
    end
  end

  def initialize(
    env: ENV,
    rails_config: Rails.application.config,
    application_mailer_from: nil,
    devise_mailer_sender: nil,
    legal_documents_validator: ProductionLegalDocumentsValidator,
    strict: Rails.env.production?
  )
    @env = env
    @rails_config = rails_config
    @application_mailer_from = application_mailer_from
    @devise_mailer_sender = devise_mailer_sender
    @legal_documents_validator = legal_documents_validator
    @strict = strict
    @runtime_config = ProductionRuntimeConfig.new(env: env)
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
    missing += missing_encryption_keys
    missing += missing_ocr_keys
    missing += missing_ai_keys
    missing += missing_turnstile_keys
    missing += invalid_database_configuration_keys
    missing += missing_legal_document_file_items
    missing + missing_mail_configuration_keys
  end

  def missing_legal_document_file_items
    legal_documents_validator.call(database: false).missing_items
  end

  def missing_encryption_keys
    encryption_config = rails_config.active_record.encryption

    ENCRYPTION_REQUIRED.filter_map do |key, config_method|
      key if blank_value?(encryption_config.public_send(config_method))
    end
  end

  def missing_ocr_keys
    return [] unless env_feature_enabled?(OCR_ENABLED_ENV_KEY)

    OCR_REQUIRED_ENV.reject { |key| present_env?(key) }
  end

  def missing_ai_keys
    return [] unless env_feature_enabled?(AI_ENABLED_ENV_KEY)

    AI_REQUIRED_ENV.reject { |key| present_env?(key) }
  end

  def missing_turnstile_keys
    return [] unless truthy_env?("TURNSTILE_ENABLED")

    TURNSTILE_REQUIRED_ENV.reject { |key| present_env?(key) }
  end

  def invalid_database_configuration_keys
    invalid_tcp_port?("DB_PORT") ? [ "DB_PORT.integer" ] : []
  end

  def missing_mail_configuration_keys
    return [] unless mail_delivery_enabled?

    missing = []
    missing << "action_mailer.default_url_options.host" if placeholder?(mailer_host)
    missing << "application_mailer.default_from" if placeholder?(resolved_application_mailer_from)
    missing << "devise.mailer_sender" if placeholder?(resolved_devise_mailer_sender)
    missing << "action_mailer.smtp_settings" if smtp_delivery? && smtp_settings.blank?
    missing += runtime_config.missing_smtp_env if smtp_delivery?
    missing << "SMTP_PORT.integer" if smtp_delivery? && invalid_tcp_port?("SMTP_PORT")
    missing
  end

  def mail_delivery_enabled?
    rails_config.action_mailer.perform_deliveries != false
  end

  def mailer_host
    rails_config.action_mailer.default_url_options.to_h[:host]
  end

  def smtp_delivery?
    delivery_method = rails_config.action_mailer.delivery_method || ActionMailer::Base.delivery_method
    delivery_method.to_sym == :smtp
  end

  def smtp_settings
    rails_config.action_mailer.smtp_settings
  end

  def invalid_tcp_port?(key)
    raw_port = env[key].to_s.strip
    return false if raw_port.blank?

    port = Integer(raw_port, 10)
    port < 1 || port > 65_535
  rescue ArgumentError
    true
  end

  def runtime_config
    @runtime_config
  end

  def env_feature_enabled?(key)
    boolean_type.cast(env.fetch(key, "true"))
  end

  def truthy_env?(key)
    boolean_type.cast(env[key])
  end

  def boolean_type
    @boolean_type ||= ActiveModel::Type::Boolean.new
  end

  def present_env?(key)
    env[key].to_s.strip.present?
  end

  def blank_value?(value)
    value.to_s.strip.blank?
  end

  def placeholder?(value)
    normalized = value.to_s.strip
    normalized.blank? || PLACEHOLDER_VALUES.include?(normalized)
  end

  def resolved_application_mailer_from
    application_mailer_from || "ApplicationMailer".safe_constantize&.default&.[](:from)
  end

  def resolved_devise_mailer_sender
    return devise_mailer_sender if devise_mailer_sender.present?
    return unless defined?(Devise)

    Devise.mailer_sender
  end

  def error_message(keys)
    "Missing required production environment configuration: #{keys.join(', ')}"
  end

  attr_reader :application_mailer_from, :devise_mailer_sender, :legal_documents_validator
end
