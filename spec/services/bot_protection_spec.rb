require "rails_helper"

RSpec.describe BotProtection do
  around do |example|
    original_enabled = ENV["TURNSTILE_ENABLED"]
    original_site_key = ENV["TURNSTILE_SITE_KEY"]
    original_secret_key = ENV["TURNSTILE_SECRET_KEY"]
    original_timeout = ENV["TURNSTILE_TIMEOUT"]

    example.run
  ensure
    ENV["TURNSTILE_ENABLED"] = original_enabled
    ENV["TURNSTILE_SITE_KEY"] = original_site_key
    ENV["TURNSTILE_SECRET_KEY"] = original_secret_key
    ENV["TURNSTILE_TIMEOUT"] = original_timeout
  end

  describe ".verify_turnstile" do
    it "disabledなら成功扱いにする" do
      ENV["TURNSTILE_ENABLED"] = "false"

      result = described_class.verify_turnstile(token: nil, remote_ip: "203.0.113.10")

      aggregate_failures do
        expect(result).to be_success
        expect(result.error_code).to be_nil
      end
    end

    it "enabledでsite keyかsecret keyが不足している場合は失敗する" do
      ENV["TURNSTILE_ENABLED"] = "true"
      ENV["TURNSTILE_SITE_KEY"] = "site_key"
      ENV.delete("TURNSTILE_SECRET_KEY")

      result = described_class.verify_turnstile(token: "token", remote_ip: "203.0.113.10")

      aggregate_failures do
        expect(result).to be_failed
        expect(result.error_code).to eq("turnstile_not_configured")
      end
    end

    it "enabledでtokenがない場合は失敗する" do
      configure_enabled_turnstile

      result = described_class.verify_turnstile(token: "", remote_ip: "203.0.113.10")

      aggregate_failures do
        expect(result).to be_failed
        expect(result.error_code).to eq("turnstile_token_missing")
      end
    end

    it "siteverify successなら成功する" do
      configure_enabled_turnstile
      stub_siteverify_response(success: true)

      result = described_class.verify_turnstile(token: "token", remote_ip: "203.0.113.10")

      expect(result).to be_success
    end

    it "siteverify failureなら失敗する" do
      configure_enabled_turnstile
      stub_siteverify_response(success: false, error_codes: [ "invalid-input-response" ])

      result = described_class.verify_turnstile(token: "token", remote_ip: "203.0.113.10")

      aggregate_failures do
        expect(result).to be_failed
        expect(result.error_code).to eq("turnstile_invalid_input_response")
      end
    end

    it "timeoutやnetwork errorは失敗する" do
      configure_enabled_turnstile
      allow(Net::HTTP).to receive(:new).and_raise(Net::OpenTimeout)

      result = described_class.verify_turnstile(token: "token", remote_ip: "203.0.113.10")

      aggregate_failures do
        expect(result).to be_failed
        expect(result.error_code).to eq("turnstile_unavailable")
      end
    end

    it "secretやtokenを返却値に含めない" do
      configure_enabled_turnstile
      stub_siteverify_response(success: false, error_codes: [ "invalid-input-secret" ])

      result = described_class.verify_turnstile(token: "sensitive-token", remote_ip: "203.0.113.10")

      serialized = result.to_h.values.join(" ")
      aggregate_failures do
        expect(serialized).not_to include("secret_key")
        expect(serialized).not_to include("sensitive-token")
      end
    end
  end

  def configure_enabled_turnstile
    ENV["TURNSTILE_ENABLED"] = "true"
    ENV["TURNSTILE_SITE_KEY"] = "site_key"
    ENV["TURNSTILE_SECRET_KEY"] = "secret_key"
  end

  def stub_siteverify_response(success:, error_codes: [])
    http = instance_double(Net::HTTP)
    response = instance_double(Net::HTTPSuccess, body: { success: success, "error-codes": error_codes }.to_json)

    allow(Net::HTTP).to receive(:new).with("challenges.cloudflare.com", 443).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
  end
end
