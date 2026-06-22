# frozen_string_literal: true

require "ipaddr"

module Security
  class IpAddress
    RESERVED_RANGES = [
      IPAddr.new("0.0.0.0/8"),
      IPAddr.new("100.64.0.0/10"),
      IPAddr.new("127.0.0.0/8"),
      IPAddr.new("169.254.0.0/16"),
      IPAddr.new("192.0.0.0/24"),
      IPAddr.new("192.0.2.0/24"),
      IPAddr.new("198.18.0.0/15"),
      IPAddr.new("198.51.100.0/24"),
      IPAddr.new("203.0.113.0/24"),
      IPAddr.new("224.0.0.0/4"),
      IPAddr.new("240.0.0.0/4"),
      IPAddr.new("255.255.255.255/32"),
      IPAddr.new("::/128"),
      IPAddr.new("::1/128"),
      IPAddr.new("fc00::/7"),
      IPAddr.new("fe80::/10"),
      IPAddr.new("ff00::/8"),
      IPAddr.new("2001:db8::/32")
    ].freeze

    class << self
      def normalize(value)
        raw = value.respond_to?(:to_s) ? value.to_s.strip : ""
        return if raw.blank?

        IPAddr.new(raw).to_s
      rescue IPAddr::InvalidAddressError, ArgumentError
        nil
      end

      def valid?(value)
        normalize(value).present?
      end

      def blockable?(value)
        normalized = normalize(value)
        return false if normalized.blank?

        non_blockable_reason(normalized).blank?
      end

      def non_blockable_reason(value)
        normalized = normalize(value)
        return "invalid_ip" if normalized.blank?

        ip = IPAddr.new(normalized)
        return "private_ip" if ip.private?
        return "loopback_ip" if ip.loopback?
        return "link_local_ip" if ip.link_local?
        return "reserved_ip" if RESERVED_RANGES.any? { |range| range.include?(ip) }

        nil
      rescue IPAddr::InvalidAddressError, ArgumentError
        "invalid_ip"
      end
    end
  end
end
