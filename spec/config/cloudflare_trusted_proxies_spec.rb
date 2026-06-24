# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("config/cloudflare_trusted_proxies")

RSpec.describe Recify::CloudflareTrustedProxies do
  it "keeps Rails default trusted proxies while adding Cloudflare ranges" do
    proxies = described_class.action_dispatch_trusted_proxies

    aggregate_failures do
      expect(proxies).to include(*ActionDispatch::RemoteIp::TRUSTED_PROXIES)
      expect(described_class::CLOUDFLARE_IPV4_CIDRS.size).to eq(15)
      expect(described_class::CLOUDFLARE_IPV6_CIDRS.size).to eq(7)
      expect(proxies).to include(*described_class.cloudflare_proxy_ranges)
    end
  end

  it "lets ActionDispatch and Rack resolve Cloudflare traffic to the same real client IP" do
    original_ip_filter = Rack::Request.ip_filter
    Rack::Request.ip_filter = described_class.rack_ip_filter
    resolved = {}
    app = lambda do |env|
      request = ActionDispatch::Request.new(env)
      resolved[:request_ip] = request.ip
      resolved[:remote_ip] = request.remote_ip
      [ 200, {}, [] ]
    end
    middleware = ActionDispatch::RemoteIp.new(
      app,
      true,
      described_class.action_dispatch_trusted_proxies
    )

    middleware.call(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "172.18.0.2",
        "HTTP_CF_CONNECTING_IP" => "8.8.8.8",
        "HTTP_X_FORWARDED_FOR" => "8.8.8.8, 172.70.1.2, 172.18.0.2"
      )
    )

    expect(resolved).to eq(request_ip: "8.8.8.8", remote_ip: "8.8.8.8")
  ensure
    Rack::Request.ip_filter = original_ip_filter
  end
end
