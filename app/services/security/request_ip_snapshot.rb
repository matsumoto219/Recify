# frozen_string_literal: true

module Security
  class RequestIpSnapshot
    HEADER_NAMES = {
      x_forwarded_for: "X-Forwarded-For",
      cf_connecting_ip: "CF-Connecting-IP",
      true_client_ip: "True-Client-IP",
      x_real_ip: "X-Real-IP",
      cf_ray: "CF-Ray",
      cf_visitor: "CF-Visitor"
    }.freeze
    HEADER_LIMIT = 5
    VALUE_LIMIT = 80

    class << self
      def call(request:)
        new(request: request).call
      end
    end

    def initialize(request:)
      @request = request
    end

    def call
      return unknown_snapshot if request.blank?

      {
        status: status,
        status_message_key: "admin.ip_diagnostics.status_messages.#{status}",
        request_ip: request_ip,
        remote_ip: remote_ip,
        rack_attack_ip: rack_attack_ip,
        rack_attack_source: "request.ip",
        cloudflare: cloudflare_snapshot,
        forwarded: forwarded_snapshot,
        headers: header_snapshot,
        trusted_proxy: trusted_proxy_snapshot,
        direct_origin: direct_origin_snapshot,
        checks: checks
      }
    end

    private

    attr_reader :request

    def unknown_snapshot
      {
        status: "unknown",
        status_message_key: "admin.ip_diagnostics.status_messages.unknown",
        request_ip: nil,
        remote_ip: nil,
        rack_attack_ip: nil,
        rack_attack_source: "request.ip",
        cloudflare: { likely: false, header_keys: [] },
        forwarded: { present: false, count: 0, values: [], omitted_count: 0 },
        headers: {},
        trusted_proxy: trusted_proxy_snapshot,
        direct_origin: { possible: true, reason_key: "admin.ip_diagnostics.direct_origin.reasons.no_request" },
        checks: [ check("unknown", "admin.ip_diagnostics.checks.no_request") ]
      }
    end

    def status
      return "unknown" if request_ip.blank? || rack_attack_ip.blank?
      return "danger" if cloudflare_client_ip.present? && rack_attack_ip != cloudflare_client_ip
      return "danger" if cloudflare_client_ip.present? && remote_ip.present? && remote_ip != cloudflare_client_ip
      return "ok" if cloudflare_client_ip.present? && rack_attack_ip == cloudflare_client_ip && remote_ip == cloudflare_client_ip
      return "warning" if cloudflare_headers_present? || forwarded_ips.present?

      "warning"
    end

    def checks
      [
        rack_attack_check,
        remote_ip_check,
        cloudflare_check,
        direct_origin_check
      ].compact
    end

    def rack_attack_check
      if rack_attack_ip.blank?
        check("danger", "admin.ip_diagnostics.checks.rack_attack_ip_missing")
      elsif cloudflare_client_ip.present? && rack_attack_ip != cloudflare_client_ip
        check("danger", "admin.ip_diagnostics.checks.rack_attack_ip_mismatch")
      elsif cloudflare_client_ip.present?
        check("ok", "admin.ip_diagnostics.checks.rack_attack_ip_matches_cloudflare")
      else
        check("warning", "admin.ip_diagnostics.checks.rack_attack_ip_unverified")
      end
    end

    def remote_ip_check
      if remote_ip.blank?
        check("danger", "admin.ip_diagnostics.checks.remote_ip_missing")
      elsif cloudflare_client_ip.present? && remote_ip != cloudflare_client_ip
        check("danger", "admin.ip_diagnostics.checks.remote_ip_mismatch")
      elsif cloudflare_client_ip.present?
        check("ok", "admin.ip_diagnostics.checks.remote_ip_matches_cloudflare")
      else
        check("warning", "admin.ip_diagnostics.checks.remote_ip_unverified")
      end
    end

    def cloudflare_check
      if cloudflare_headers_present?
        check("ok", "admin.ip_diagnostics.checks.cloudflare_headers_present")
      else
        check("warning", "admin.ip_diagnostics.checks.cloudflare_headers_missing")
      end
    end

    def direct_origin_check
      return check("warning", "admin.ip_diagnostics.checks.direct_origin_must_be_restricted") if cloudflare_headers_present?

      check("warning", "admin.ip_diagnostics.checks.direct_origin_unverified")
    end

    def check(level, message_key)
      {
        level: level,
        message_key: message_key
      }
    end

    def cloudflare_snapshot
      {
        likely: cloudflare_headers_present?,
        header_keys: HEADER_NAMES.slice(:cf_connecting_ip, :true_client_ip, :cf_ray, :cf_visitor).filter_map do |key, header_name|
          header_present?(key) ? header_name : nil
        end,
        connecting_ip: safe_header_value(:cf_connecting_ip),
        true_client_ip: safe_header_value(:true_client_ip),
        ray_present: header_present?(:cf_ray),
        visitor_present: header_present?(:cf_visitor)
      }
    end

    def forwarded_snapshot
      {
        present: forwarded_ips.present?,
        count: forwarded_ips.size,
        values: forwarded_ips.first(HEADER_LIMIT),
        omitted_count: [ forwarded_ips.size - HEADER_LIMIT, 0 ].max
      }
    end

    def header_snapshot
      HEADER_NAMES.each_with_object({}) do |(_key, header_name), snapshot|
        raw = header(header_name)
        values = header_name == "X-Forwarded-For" ? split_forwarded_for(raw) : [ raw.to_s.strip.presence ].compact
        snapshot[header_name] = {
          present: raw.present?,
          count: values.size,
          values: values.first(HEADER_LIMIT).map { |value| truncate_value(value) },
          omitted_count: [ values.size - HEADER_LIMIT, 0 ].max
        }
      end
    end

    def trusted_proxy_snapshot
      custom_proxies = Rails.application.config.action_dispatch.trusted_proxies
      {
        custom_configured: custom_proxies.present?,
        mode: custom_proxies.present? ? "custom" : "rails_default"
      }
    end

    def direct_origin_snapshot
      {
        possible: true,
        reason_key: if cloudflare_headers_present?
                      "admin.ip_diagnostics.direct_origin.reasons.cloudflare_headers_do_not_prove_origin_lock"
                    else
                      "admin.ip_diagnostics.direct_origin.reasons.no_cloudflare_headers"
                    end
      }
    end

    def cloudflare_headers_present?
      header_present?(:cf_connecting_ip) ||
        header_present?(:true_client_ip) ||
        header_present?(:cf_ray) ||
        header_present?(:cf_visitor)
    end

    def cloudflare_client_ip
      @cloudflare_client_ip ||= IpAddress.normalize(header("CF-Connecting-IP")) || IpAddress.normalize(header("True-Client-IP"))
    end

    def forwarded_ips
      @forwarded_ips ||= split_forwarded_for(header("X-Forwarded-For")).filter_map do |value|
        IpAddress.normalize(value) || truncate_value(value)
      end
    end

    def split_forwarded_for(value)
      value.to_s.split(",").map(&:strip).filter_map(&:presence)
    end

    def safe_header_value(key)
      truncate_value(header(HEADER_NAMES.fetch(key)))
    end

    def header_present?(key)
      header(HEADER_NAMES.fetch(key)).present?
    end

    def header(name)
      request.get_header("HTTP_#{name.tr('-', '_').upcase}")
    rescue NoMethodError
      nil
    end

    def request_ip
      @request_ip ||= request.ip.to_s.presence
    rescue NoMethodError
      nil
    end

    def remote_ip
      @remote_ip ||= request.remote_ip.to_s.presence
    rescue NoMethodError
      nil
    end

    def rack_attack_ip
      request_ip
    end

    def truncate_value(value)
      value.to_s.strip.truncate(VALUE_LIMIT, omission: "...")
    end
  end
end
