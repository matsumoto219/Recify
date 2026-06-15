# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecifyContentSecurityPolicy do
  def built_policy
    policy = ActionDispatch::ContentSecurityPolicy.new
    described_class.apply(policy)
    policy.build(ActionController::Base.new, false)
  end

  it "defines a report-only friendly policy for production" do
    policy = built_policy

    expect(policy).to include("default-src 'self'")
    expect(policy).to include("base-uri 'self'")
    expect(policy).to include("object-src 'none'")
    expect(policy).to include("frame-ancestors 'none'")
    expect(policy).to include("form-action 'self'")
  end

  it "allows importmap application assets, Turnstile, Google Fonts, and local media sources" do
    policy = built_policy

    expect(policy).to include("script-src 'self' https://challenges.cloudflare.com")
    expect(policy).to include("frame-src https://challenges.cloudflare.com")
    expect(policy).to include("connect-src 'self' https://challenges.cloudflare.com")
    expect(policy).to include("style-src 'self' 'unsafe-inline' https://fonts.googleapis.com")
    expect(policy).to include("font-src 'self' data: https://fonts.gstatic.com")
    expect(policy).to include("img-src 'self' data: blob:")
  end

  it "configures report-only mode without enabling an enforcing policy outside production" do
    config = ActiveSupport::OrderedOptions.new
    config.content_security_policy_report_only = false

    def config.content_security_policy(&block)
      @content_security_policy_block = block
    end

    described_class.configure(config, report_only: true)

    expect(config.content_security_policy_report_only).to eq(true)
    expect(config.content_security_policy_nonce_directives).to eq(%w[script-src])
    expect(config.content_security_policy_nonce_auto).to eq(true)
    expect(config.content_security_policy_nonce_generator.call(double)).to be_present
  end
end
