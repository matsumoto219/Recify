# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Content Security Policy", type: :request do
  around do |example|
    original_policy = Rails.application.config.content_security_policy
    original_report_only = Rails.application.config.content_security_policy_report_only
    original_nonce_generator = Rails.application.config.content_security_policy_nonce_generator
    original_nonce_directives = Rails.application.config.content_security_policy_nonce_directives
    original_nonce_auto = Rails.application.config.content_security_policy_nonce_auto

    RecifyContentSecurityPolicy.configure(Rails.application.config, report_only: true)
    example.run
  ensure
    Rails.application.config.instance_variable_set(:@content_security_policy, original_policy)
    Rails.application.config.content_security_policy_report_only = original_report_only
    Rails.application.config.content_security_policy_nonce_generator = original_nonce_generator
    Rails.application.config.content_security_policy_nonce_directives = original_nonce_directives
    Rails.application.config.content_security_policy_nonce_auto = original_nonce_auto
  end

  it "emits report-only CSP headers without enforcing CSP headers" do
    get root_path

    expect(response.headers["Content-Security-Policy-Report-Only"]).to include("default-src 'self'")
    expect(response.headers["Content-Security-Policy-Report-Only"]).to include("frame-ancestors 'none'")
    expect(response.headers["Content-Security-Policy-Report-Only"]).to include("object-src 'none'")
    expect(response.headers["Content-Security-Policy-Report-Only"]).to include("https://challenges.cloudflare.com")
    expect(response.headers["Content-Security-Policy"]).to be_blank
  end
end
