# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Content Security Policy", type: :request do
  it "emits report-only CSP headers without enforcing CSP headers" do
    policy = ActionDispatch::ContentSecurityPolicy.new
    RecifyContentSecurityPolicy.apply(policy)
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    env = Rack::MockRequest.env_for("/")
    env[ActionDispatch::ContentSecurityPolicy::Request::POLICY] = policy
    env[ActionDispatch::ContentSecurityPolicy::Request::POLICY_REPORT_ONLY] = true
    env[ActionDispatch::ContentSecurityPolicy::Request::NONCE_GENERATOR] = ->(_request) { "test-nonce" }
    env[ActionDispatch::ContentSecurityPolicy::Request::NONCE_DIRECTIVES] = %w[script-src]

    _status, headers, _body = ActionDispatch::ContentSecurityPolicy::Middleware.new(app).call(env)

    report_only_header = headers["Content-Security-Policy-Report-Only"] ||
      headers["content-security-policy-report-only"]

    expect(report_only_header).to include("default-src 'self'")
    expect(report_only_header).to include("frame-ancestors 'none'")
    expect(report_only_header).to include("object-src 'none'")
    expect(report_only_header).to include("https://challenges.cloudflare.com")
    expect(headers["Content-Security-Policy"] || headers["content-security-policy"]).to be_blank
  end
end
