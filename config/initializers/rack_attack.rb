# frozen_string_literal: true

require "cgi"

class Rack::Attack
  Rack::Attack.cache.store = Rails.cache
  Rack::Attack.throttled_response_retry_after_header = true

  BASIC_THROTTLE_SKIP_PATH = %r{\A/(?:up\z|assets/|rails/active_storage/|favicon\.ico\z|robots\.txt\z|letter_opener)}.freeze
  SCANNER_PATH = %r{(?:\A|/)(?:\.env|wp-login\.php|wp-admin|xmlrpc\.php|phpmyadmin|pma|etc/passwd|vendor/phpunit|cgi-bin)}i.freeze

  class << self
    def throttleable_request?(request)
      !BASIC_THROTTLE_SKIP_PATH.match?(request.path.to_s)
    end

    def scanner_request?(request)
      path = request.path.to_s
      query = CGI.unescape(request.query_string.to_s)

      SCANNER_PATH.match?(path) || SCANNER_PATH.match?(query)
    rescue ArgumentError
      SCANNER_PATH.match?(path)
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

    def basic_error_html(status:, title:, description:)
      escaped_title = ERB::Util.html_escape(title)
      escaped_description = ERB::Util.html_escape(description)

      <<~HTML
        <!doctype html>
        <html lang="ja">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{escaped_title}</title>
          </head>
          <body>
            <main>
              <h1>#{escaped_title}</h1>
              <p>#{escaped_description}</p>
              <p>Error Code: #{status}</p>
            </main>
          </body>
        </html>
      HTML
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
        else
          basic_error_html(status: status, title: title, description: description)
        end

      [ status, response_headers, [ body ] ]
    end
  end

  blocklist("fail2ban/scanner_paths") do |request|
    Rack::Attack::Fail2Ban.filter("scanner:#{request.ip}", maxretry: 3, findtime: 10.minutes, bantime: 30.minutes) do
      Rack::Attack.scanner_request?(request)
    end
  end

  throttle("requests/ip", limit: 300, period: 5.minutes) do |request|
    request.ip if Rack::Attack.throttleable_request?(request)
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
    Rack::Attack.rack_response(request, status: 403, i18n_scope: :forbidden)
  end
end
