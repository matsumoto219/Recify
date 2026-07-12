# frozen_string_literal: true

require "cgi"

class Rack::Attack
  Rack::Attack.cache.store = Rails.cache
  Rack::Attack.throttled_response_retry_after_header = true

  BASIC_THROTTLE_SKIP_PATH = %r{\A/(?:up\z|assets/|rails/active_storage/|favicon\.ico\z|robots\.txt\z|letter_opener)}.freeze
  ADMIN_PROBE_MAXRETRY = 20
  ADMIN_PROBE_FINDTIME = 10.minutes
  ADMIN_PROBE_BANTIME = 30.minutes
  ADMIN_PROBE_PATH = %r{
    \A/
    (?:
      admin/(?:login(?:\.php)?|index\.php|admin\.php)
      |admin\.php
      |adminer
      |administrator
      |cpanel
      |webadmin
      |manager
      |cms
      |wp-admin(?:/|\z)
      |wp-login\.php
    )
    (?:\z|[/?#])
  }ix.freeze
  ADMIN_SERVICE_STATUS_PATH = %r{\A/admin/external_services/status(?:\z|[/?#])}.freeze
  RECEIPT_PROCESSING_CARDS_PATH = "/receipts/processing_cards".freeze
  ACTIVE_STORAGE_DIRECT_UPLOAD_PATH = "/rails/active_storage/direct_uploads"
  SCANNER_PATH = %r{
    (?:\A|/)(?:\.env|\.env\.[^/?#]+|\.git(?:/config)?|wp-login\.php|xmlrpc\.php|etc/passwd|windows/win\.ini|boot\.ini)(?:\z|[/?#])
    |\A/[^/?#\/]+\.php(?:\z|[?#])
    |(?:\A|/)(?:wp-admin|wp-content|wp-includes|phpmyadmin|pma|vendor/phpunit|cgi-bin)(?:\z|[/?#])
    |(?:\A|/)(?:config/(?:master\.key|credentials\.yml\.enc|database\.yml)|db/(?:production|development)\.sqlite3|backup\.sql|dump\.sql)(?:\z|[/?#])
    |(?:\A|/)(?:composer\.(?:json|lock)|package\.json|yarn\.lock|pnpm-lock\.yaml|firebase\.json|amplify\.yml)(?:\z|[/?#])
    |(?:\A|/)(?:vite|next|nuxt)\.config\.[^/?#]+(?:\z|[/?#])
    |\A/(?:backup|dump)[^/?#]*(?:\z|[?#])
    |(?:\A|/)rails/(?:info/(?:routes|properties)|mailers|conductor)(?:\z|[/?#])
    |(?:\A|/)(?:sidekiq|admin/sidekiq|solid_queue|admin/solid_queue)(?:\z|[/?#])
    |\.(?:sql|bak|old|backup|orig|save|swp)(?:\z|[/?#])
    |\.\.(?:/|\\|%2f|%5c)
    |%(?:25)?2e%(?:25)?2e(?:/|\\|%(?:25)?2f|%(?:25)?5c)
    |\.\.%(?:25)?2f
    |\.\.%(?:25)?5c
  }ix.freeze

  class << self
    def throttleable_request?(request)
      !BASIC_THROTTLE_SKIP_PATH.match?(request.path.to_s) && !receipt_processing_cards_request?(request)
    end

    def receipt_processing_cards_request?(request)
      request.get? && request.path.to_s == RECEIPT_PROCESSING_CARDS_PATH
    end

    def scanner_request?(request)
      path = request.path.to_s
      query = CGI.unescape(request.query_string.to_s)

      SCANNER_PATH.match?(path) || SCANNER_PATH.match?(query)
    rescue ArgumentError
      SCANNER_PATH.match?(path)
    end

    def admin_probe_request?(request)
      path = request.path.to_s

      return false unless ADMIN_PROBE_PATH.match?(path)
      return false if ADMIN_SERVICE_STATUS_PATH.match?(path) && json_request?(request)

      true
    end

    def active_storage_direct_upload_probe?(request)
      request.post? && request.path.to_s == ACTIVE_STORAGE_DIRECT_UPLOAD_PATH
    end

    def json_request?(request)
      request.get_header("HTTP_ACCEPT").to_s.include?("application/json") ||
        request.get_header("CONTENT_TYPE").to_s.include?("application/json")
    end

    def retry_after_for(request)
      match_data = request.env.fetch("rack.attack.match_data", {})
      period = match_data[:period].to_i
      epoch_time = match_data[:epoch_time].to_i
      return period if period.positive? && epoch_time.zero?

      remaining = period - (epoch_time % period)
      remaining.positive? ? remaining : 1
    end

    def too_many_requests_html(retry_after)
      ApplicationController.render(
        template: "errors/too_many_requests",
        layout: "error",
        locals: { retry_after: retry_after }
      )
    end

    def forbidden_html
      ApplicationController.render(
        template: "errors/forbidden",
        layout: "error"
      )
    end

    def rack_response(request, status:, i18n_scope:, headers: {}, retry_after: nil)
      title = I18n.t("errors.#{i18n_scope}.title")
      description = I18n.t("errors.#{i18n_scope}.description")
      response_headers = {
        "Content-Type" => json_request?(request) ? "application/json; charset=utf-8" : "text/html; charset=utf-8"
      }.merge(headers)

      body =
        if json_request?(request)
          payload = { error: title, message: description, status: status }
          payload[:retry_after] = retry_after.to_i if retry_after.to_i.positive?
          JSON.generate(payload)
        elsif status == 429 && i18n_scope == :too_many_requests
          too_many_requests_html(retry_after)
        elsif status == 403 && i18n_scope == :forbidden
          forbidden_html
        else
          raise ArgumentError, "Unsupported Rack::Attack HTML error response: status=#{status} scope=#{i18n_scope}"
        end

      [ status, response_headers, [ body ] ]
    end
  end

  blocklist("manual/ip_blocks") do |request|
    Security.ip_blocked?(request.ip)
  end

  blocklist("fail2ban/scanner_paths") do |request|
    Rack::Attack::Fail2Ban.filter("scanner:#{request.ip}", maxretry: 3, findtime: 10.minutes, bantime: 30.minutes) do
      Rack::Attack.scanner_request?(request)
    end
  end

  blocklist("fail2ban/admin_probes") do |request|
    Rack::Attack::Allow2Ban.filter(
      "admin_probe:#{request.ip}",
      maxretry: ADMIN_PROBE_MAXRETRY,
      findtime: ADMIN_PROBE_FINDTIME,
      bantime: ADMIN_PROBE_BANTIME
    ) do
      Rack::Attack.admin_probe_request?(request)
    end
  end

  # Direct uploads are intentionally unavailable. Remove this rule if direct uploads are enabled.
  blocklist("fail2ban/active_storage_direct_uploads") do |request|
    Rack::Attack::Fail2Ban.filter("direct_upload_probe:#{request.ip}", maxretry: 3, findtime: 10.minutes, bantime: 30.minutes) do
      Rack::Attack.active_storage_direct_upload_probe?(request)
    end
  end

  throttle("requests/ip", limit: 300, period: 5.minutes) do |request|
    request.ip if Rack::Attack.throttleable_request?(request)
  end

  throttle("receipts/processing_cards/ip", limit: 600, period: 5.minutes) do |request|
    request.ip if Rack::Attack.receipt_processing_cards_request?(request)
  end

  throttle("auth/sign_in/ip", limit: 20, period: 5.minutes) do |request|
    request.ip if request.post? && request.path == "/users/sign_in"
  end

  throttle("auth/password/ip", limit: 10, period: 10.minutes) do |request|
    request.ip if request.post? && request.path == "/users/password"
  end

  throttle("auth/confirmation/ip", limit: 10, period: 10.minutes) do |request|
    request.ip if request.post? && request.path == "/users/confirmation"
  end

  throttle("auth/unlock/ip", limit: 10, period: 10.minutes) do |request|
    request.ip if request.post? && request.path == "/users/unlock"
  end

  throttle("auth/registration/ip", limit: 10, period: 1.hour) do |request|
    request.ip if request.post? && request.path == "/users"
  end

  throttle("auth/guest_sign_in/ip", limit: 10, period: 1.hour) do |request|
    request.ip if request.post? && request.path == "/users/guest_sign_in"
  end

  throttle("receipts/upload/ip", limit: 30, period: 1.hour) do |request|
    request.ip if request.post? && request.path == "/receipts/upload"
  end

  self.throttled_responder = lambda do |request|
    retry_after = Rack::Attack.retry_after_for(request)
    SecurityEvents.record_rate_limit!(
      request: request,
      matched_rule: request.env["rack.attack.matched"],
      retry_after: retry_after,
      metadata: request.env.fetch("rack.attack.match_data", {})
    )
    response_headers = { "Retry-After" => retry_after.to_s }
    response_headers["Turbo-Visit-Control"] = "reload" unless Rack::Attack.json_request?(request)

    Rack::Attack.rack_response(
      request,
      status: 429,
      i18n_scope: :too_many_requests,
      headers: response_headers,
      retry_after: retry_after
    )
  end

  self.blocklisted_responder = lambda do |request|
    SecurityEvents.record_rate_limit!(
      request: request,
      matched_rule: request.env["rack.attack.matched"].presence || "rack_attack_blocklist"
    )
    response_headers = {}
    response_headers["Turbo-Visit-Control"] = "reload" unless Rack::Attack.json_request?(request)

    Rack::Attack.rack_response(
      request,
      status: 403,
      i18n_scope: :forbidden,
      headers: response_headers
    )
  end
end
