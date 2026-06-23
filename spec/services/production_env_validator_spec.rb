# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductionEnvValidator do
  let(:rails_config) do
    ActiveSupport::OrderedOptions.new.tap do |config|
      config.active_record = ActiveSupport::OrderedOptions.new
      config.active_record.encryption = ActiveSupport::OrderedOptions.new
      config.active_record.encryption.primary_key = "primary"
      config.active_record.encryption.deterministic_key = "deterministic"
      config.active_record.encryption.key_derivation_salt = "salt"
      config.action_mailer = ActiveSupport::OrderedOptions.new
      config.action_mailer.perform_deliveries = true
      config.action_mailer.default_url_options = { host: "recify-app.com" }
      config.action_mailer.delivery_method = :smtp
      config.action_mailer.smtp_settings = {
        address: "smtp.example.test",
        port: 587,
        user_name: "smtp-user",
        password: "smtp-password"
      }
    end
  end

  let(:required_env) do
    {
      "RAILS_MASTER_KEY" => "master",
      "RECIFY_DATABASE_PASSWORD" => "database",
      "APP_HOST" => "recify-app.com",
      "WEBAUTHN_RP_ID" => "recify-app.com",
      "WEBAUTHN_ALLOWED_ORIGINS" => "https://recify-app.com",
      "SUPPORT_NOTIFICATION_EMAIL" => "support@example.test",
      "SMTP_HOST" => "smtp.example.test",
      "SMTP_PORT" => "587",
      "SMTP_USERNAME" => "smtp-user",
      "SMTP_PASSWORD" => "smtp-password",
      "SMTP_FROM" => "noreply@example.test",
      "AZURE_OCR_ENDPOINT" => "https://example.cognitiveservices.azure.com",
      "AZURE_OCR_API_KEY" => "azure-key",
      "OPENAI_API_KEY" => "openai-key",
      "OPENAI_AI_MODEL" => "gpt-test"
    }
  end

  let(:validator_options) do
    {
      application_mailer_from: "noreply@example.test",
      devise_mailer_sender: "noreply@example.test"
    }
  end

  it "production strict mode passes when required values are present" do
    result = described_class.call(env: required_env, rails_config: rails_config, strict: true, **validator_options)

    expect(result).to be_success
    expect(result.missing_keys).to be_empty
  end

  it "production strict mode includes legal document file validation" do
    legal_documents_validator = class_double(
      ProductionLegalDocumentsValidator,
      call: ProductionLegalDocumentsValidator::Result.new(
        missing_items: [ "legal_documents.files: current terms/ja was not found" ]
      )
    )

    result = described_class.call(
      env: required_env,
      rails_config: rails_config,
      strict: true,
      legal_documents_validator: legal_documents_validator,
      **validator_options
    )

    aggregate_failures do
      expect(result.missing_keys).to include("legal_documents.files: current terms/ja was not found")
      expect(legal_documents_validator).to have_received(:call).with(database: false)
    end
  end

  it "production strict mode reports all missing keys together" do
    env = required_env.except("RAILS_MASTER_KEY", "RECIFY_DATABASE_PASSWORD")
    rails_config.active_record.encryption.primary_key = nil

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("RAILS_MASTER_KEY")
      expect(error.message).to include("RECIFY_DATABASE_PASSWORD")
      expect(error.message).to include("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
    }
  end

  it "does not include secret values in error messages" do
    env = required_env.merge("RAILS_MASTER_KEY" => "super-secret-value", "SMTP_PASSWORD" => "smtp-secret-value")
    env.delete("WEBAUTHN_RP_ID")
    env.delete("SMTP_USERNAME")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("WEBAUTHN_RP_ID")
      expect(error.message).to include("SMTP_USERNAME")
      expect(error.message).not_to include("super-secret-value")
      expect(error.message).not_to include("smtp-secret-value")
    }
  end

  it "requires APP_HOST in production strict mode" do
    env = required_env.except("APP_HOST")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("APP_HOST")
    }
  end

  it "requires SUPPORT_NOTIFICATION_EMAIL in production strict mode" do
    env = required_env.except("SUPPORT_NOTIFICATION_EMAIL")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("SUPPORT_NOTIFICATION_EMAIL")
      expect(error.message).not_to include("support@example.test")
    }
  end

  it "does not fail outside strict mode" do
    result = nil

    expect do
      result = described_class.validate!(env: {}, rails_config: rails_config, strict: false, **validator_options)
    end.not_to raise_error

    expect(result).to be_success
    expect(result.missing_keys).to be_empty
  end

  it "requires Azure OCR keys when OCR is not disabled by ENV" do
    env = required_env.except("AZURE_OCR_ENDPOINT", "AZURE_OCR_API_KEY")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("AZURE_OCR_ENDPOINT")
      expect(error.message).to include("AZURE_OCR_API_KEY")
    }
  end

  it "does not require Azure OCR keys when OCR is disabled by ENV" do
    env = required_env.except("AZURE_OCR_ENDPOINT", "AZURE_OCR_API_KEY")
    env["RECEIPT_OCR_ENABLED"] = "false"

    result = described_class.call(env: env, rails_config: rails_config, strict: true, **validator_options)

    expect(result).to be_success
  end

  it "requires OpenAI keys when AI is not disabled by ENV" do
    env = required_env.except("OPENAI_API_KEY", "OPENAI_AI_MODEL")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("OPENAI_API_KEY")
      expect(error.message).to include("OPENAI_AI_MODEL")
    }
  end

  it "does not require OpenAI keys when AI is disabled by ENV" do
    env = required_env.except("OPENAI_API_KEY", "OPENAI_AI_MODEL")
    env["RECEIPT_AI_ENABLED"] = "false"

    result = described_class.call(env: env, rails_config: rails_config, strict: true, **validator_options)

    expect(result).to be_success
  end

  it "requires Turnstile keys only when Turnstile is enabled" do
    env = required_env.merge("TURNSTILE_ENABLED" => "true")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("TURNSTILE_SITE_KEY")
      expect(error.message).to include("TURNSTILE_SECRET_KEY")
    }
  end

  it "does not require Turnstile keys when Turnstile is disabled" do
    env = required_env.merge("TURNSTILE_ENABLED" => "false")

    result = described_class.call(env: env, rails_config: rails_config, strict: true, **validator_options)

    expect(result).to be_success
  end

  it "reports production mail placeholders when delivery is enabled" do
    rails_config.action_mailer.default_url_options = { host: "example.com" }
    rails_config.action_mailer.smtp_settings = nil

    expect do
      described_class.validate!(
        env: required_env,
        rails_config: rails_config,
        application_mailer_from: "from@example.com",
        devise_mailer_sender: "please-change-me-at-config-initializers-devise@example.com",
        strict: true
      )
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("action_mailer.default_url_options.host")
      expect(error.message).to include("application_mailer.default_from")
      expect(error.message).to include("devise.mailer_sender")
      expect(error.message).to include("action_mailer.smtp_settings")
    }
  end

  it "requires SMTP ENV keys when SMTP delivery is enabled" do
    env = required_env.except("SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_FROM")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("SMTP_PORT")
      expect(error.message).to include("SMTP_USERNAME")
      expect(error.message).to include("SMTP_PASSWORD")
      expect(error.message).to include("SMTP_FROM")
    }
  end

  it "requires SMTP_PORT to be a valid TCP port when SMTP delivery is enabled" do
    env = required_env.merge("SMTP_PORT" => "not-a-port")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true, **validator_options)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("SMTP_PORT.integer")
      expect(error.message).not_to include("not-a-port")
    }
  end

  it "rejects SMTP_PORT values outside the TCP port range" do
    env = required_env.merge("SMTP_PORT" => "70000")

    result = described_class.call(env: env, rails_config: rails_config, strict: true, **validator_options)

    expect(result.missing_keys).to include("SMTP_PORT.integer")
  end

  it "does not require SMTP settings when mail delivery is disabled" do
    rails_config.action_mailer.perform_deliveries = false
    rails_config.action_mailer.default_url_options = { host: "example.com" }
    rails_config.action_mailer.smtp_settings = nil

    result = described_class.call(
      env: required_env,
      rails_config: rails_config,
      application_mailer_from: "from@example.com",
      devise_mailer_sender: "please-change-me-at-config-initializers-devise@example.com",
      strict: true
    )

    expect(result).to be_success
  end
end
