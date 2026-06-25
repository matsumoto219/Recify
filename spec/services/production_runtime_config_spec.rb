# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductionRuntimeConfig do
  describe "#app_host" do
    it "APP_HOSTを本番URL hostとして使う" do
      config = described_class.new(env: { "APP_HOST" => "recify-app.test", "DEFAULT_URL_HOST" => "legacy.test" })

      expect(config.app_host).to eq("recify-app.test")
    end

    it "DEFAULT_URL_HOSTを互換fallbackとして使う" do
      config = described_class.new(env: { "DEFAULT_URL_HOST" => "legacy.test" })

      expect(config.app_host).to eq("legacy.test")
    end
  end

  describe "URL options" do
    it "protocolをhttps既定にする" do
      config = described_class.new(env: { "APP_HOST" => "recify-app.test" })

      expect(config.routes_default_url_options).to eq(host: "recify-app.test", protocol: "https")
    end

    it "MAILER_HOSTとMAILER_PROTOCOLでmailer URLだけ上書きできる" do
      config = described_class.new(
        env: {
          "APP_HOST" => "recify-app.test",
          "MAILER_HOST" => "mail.recify-app.test",
          "MAILER_PROTOCOL" => "https://"
        }
      )

      expect(config.mailer_default_url_options).to eq(host: "mail.recify-app.test", protocol: "https")
    end
  end

  describe "#host_authorization_hosts" do
    it "APP_HOST、MAILER_HOST、APP_ADDITIONAL_HOSTSを重複なしで返す" do
      config = described_class.new(
        env: {
          "APP_HOST" => "recify-app.test",
          "MAILER_HOST" => "recify-app.test",
          "APP_ADDITIONAL_HOSTS" => "www.recify-app.test, admin.recify-app.test"
        }
      )

      expect(config.host_authorization_hosts).to eq(
        [ "recify-app.test", "www.recify-app.test", "admin.recify-app.test" ]
      )
    end
  end

  describe "SSL flags" do
    it "force_sslとassume_sslを既定で有効にする" do
      config = described_class.new(env: {})

      aggregate_failures do
        expect(config.force_ssl?).to be(true)
        expect(config.assume_ssl?).to be(true)
      end
    end

    it "ENVでcontrolled smoke check用に無効化できる" do
      config = described_class.new(env: { "FORCE_SSL" => "false", "ASSUME_SSL" => "false" })

      aggregate_failures do
        expect(config.force_ssl?).to be(false)
        expect(config.assume_ssl?).to be(false)
      end
    end

    it "HTTPS強制を維持しつつHSTS本導入を抑制するssl_optionsを返す" do
      config = described_class.new(env: {})
      health_check_request = Struct.new(:path).new("/up")
      regular_request = Struct.new(:path).new("/")

      aggregate_failures do
        expect(config.ssl_options[:hsts]).to eq(expires: 0, subdomains: false, preload: false)
        expect(config.ssl_options[:redirect][:exclude].call(health_check_request)).to be(true)
        expect(config.ssl_options[:redirect][:exclude].call(regular_request)).to be(false)
      end
    end
  end

  describe "#smtp_settings" do
    it "SMTP ENVからActionMailer設定を作る" do
      config = described_class.new(
        env: {
          "SMTP_HOST" => "smtp.example.test",
          "SMTP_PORT" => "587",
          "SMTP_USERNAME" => "smtp-user",
          "SMTP_PASSWORD" => "smtp-password",
          "SMTP_FROM" => "noreply@example.test"
        }
      )

      expect(config.smtp_settings).to include(
        address: "smtp.example.test",
        port: 587,
        user_name: "smtp-user",
        password: "smtp-password",
        authentication: :plain,
        enable_starttls_auto: true
      )
    end

    it "不足しているSMTP ENV keyを値なしで返す" do
      config = described_class.new(env: { "SMTP_HOST" => "smtp.example.test", "SMTP_PASSWORD" => "smtp-password" })

      expect(config.missing_smtp_env).to contain_exactly("SMTP_PORT", "SMTP_USERNAME", "SMTP_FROM")
    end
  end
end
