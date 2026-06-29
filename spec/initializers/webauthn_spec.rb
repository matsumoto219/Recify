require 'rails_helper'

RSpec.describe Recify::WebAuthnConfig do
  let(:production_env) { ActiveSupport::StringInquirer.new("production") }
  let(:development_env) { ActiveSupport::StringInquirer.new("development") }

  describe ".rp_id" do
    it "productionではENV未設定時にfallbackしない" do
      expect do
        described_class.rp_id(env: production_env, source: {})
      end.to raise_error(KeyError, /WEBAUTHN_RP_ID/)
    end

    it "dummy build中はproductionでもlocalhostを既定値にする" do
      rp_id = described_class.rp_id(env: production_env, source: { "SECRET_KEY_BASE_DUMMY" => "1" })

      expect(rp_id).to eq("localhost")
    end

    it "developmentではlocalhostを既定値にする" do
      expect(described_class.rp_id(env: development_env, source: {})).to eq("localhost")
    end
  end

  describe ".allowed_origins" do
    it "productionではENV未設定時にfallbackしない" do
      expect do
        described_class.allowed_origins(env: production_env, source: {})
      end.to raise_error(KeyError, /WEBAUTHN_ALLOWED_ORIGINS/)
    end

    it "dummy build中はproductionでもlocalhost originを既定値にする" do
      origins = described_class.allowed_origins(env: production_env, source: { "SECRET_KEY_BASE_DUMMY" => "1" })

      expect(origins).to eq([ "http://localhost:3000" ])
    end

    it "developmentではlocalhost originを既定値にする" do
      expect(described_class.allowed_origins(env: development_env, source: {})).to eq([ "http://localhost:3000" ])
    end
  end
end
