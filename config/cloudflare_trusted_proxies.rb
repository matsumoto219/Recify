# frozen_string_literal: true

require "action_dispatch/middleware/remote_ip"
require "ipaddr"
require "rack/request"

module Recify
  module CloudflareTrustedProxies
    SOURCE_URLS = [
      "https://www.cloudflare.com/ips-v4",
      "https://www.cloudflare.com/ips-v6"
    ].freeze

    # Fixed list from Cloudflare's official IP range endpoints.
    # Confirm this list before changing origin firewall or IP restriction policy.
    CLOUDFLARE_IPV4_CIDRS = %w[
      173.245.48.0/20
      103.21.244.0/22
      103.22.200.0/22
      103.31.4.0/22
      141.101.64.0/18
      108.162.192.0/18
      190.93.240.0/20
      188.114.96.0/20
      197.234.240.0/22
      198.41.128.0/17
      162.158.0.0/15
      104.16.0.0/13
      104.24.0.0/14
      172.64.0.0/13
      131.0.72.0/22
    ].freeze

    CLOUDFLARE_IPV6_CIDRS = %w[
      2400:cb00::/32
      2606:4700::/32
      2803:f800::/32
      2405:b500::/32
      2405:8100::/32
      2a06:98c0::/29
      2c0f:f248::/32
    ].freeze

    CLOUDFLARE_CIDRS = (CLOUDFLARE_IPV4_CIDRS + CLOUDFLARE_IPV6_CIDRS).freeze

    class << self
      def action_dispatch_trusted_proxies
        unique_proxies(ActionDispatch::RemoteIp::TRUSTED_PROXIES + cloudflare_proxy_ranges)
      end

      def rack_ip_filter(previous_filter = Rack::Request.ip_filter)
        proxies = action_dispatch_trusted_proxies

        lambda do |ip|
          previous_filter&.call(ip) == true || trusted_proxy_ip?(ip, proxies)
        end
      end

      def cloudflare_proxy_ranges
        @cloudflare_proxy_ranges ||= CLOUDFLARE_CIDRS.map { |cidr| IPAddr.new(cidr) }.freeze
      end

      private

      def trusted_proxy_ip?(value, proxies)
        ip = IPAddr.new(value)
        proxies.any? { |proxy| proxy.include?(ip) }
      rescue IPAddr::InvalidAddressError, ArgumentError
        false
      end

      def unique_proxies(proxies)
        proxies.uniq(&:to_s).freeze
      end
    end
  end
end
