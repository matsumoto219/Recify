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
    end
  end

  let(:required_env) do
    {
      "RAILS_MASTER_KEY" => "master",
      "RECIFY_DATABASE_PASSWORD" => "database",
      "WEBAUTHN_RP_ID" => "recify-app.com",
      "WEBAUTHN_ALLOWED_ORIGINS" => "https://recify-app.com",
      "SUPPORT_NOTIFICATION_EMAIL" => "support@example.test"
    }
  end

  it "production strict mode passes when required values are present" do
    result = described_class.call(env: required_env, rails_config: rails_config, strict: true)

    expect(result).to be_success
    expect(result.missing_keys).to be_empty
  end

  it "production strict mode reports all missing keys together" do
    env = required_env.except("RAILS_MASTER_KEY", "RECIFY_DATABASE_PASSWORD")
    rails_config.active_record.encryption.primary_key = nil

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("RAILS_MASTER_KEY")
      expect(error.message).to include("RECIFY_DATABASE_PASSWORD")
      expect(error.message).to include("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
    }
  end

  it "does not include secret values in error messages" do
    env = required_env.merge("RAILS_MASTER_KEY" => "super-secret-value")
    env.delete("WEBAUTHN_RP_ID")

    expect do
      described_class.validate!(env: env, rails_config: rails_config, strict: true)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("WEBAUTHN_RP_ID")
      expect(error.message).not_to include("super-secret-value")
    }
  end

  it "does not fail outside strict mode" do
    result = nil

    expect do
      result = described_class.validate!(env: {}, rails_config: rails_config, strict: false)
    end.not_to raise_error

    expect(result).to be_success
    expect(result.missing_keys).to be_empty
  end
end
