require "net/http"
require "uri"

module BotProtection
  class TurnstileVerifier
    SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
    DEFAULT_TIMEOUT = 5

    class << self
      def call(token:, remote_ip:)
        new(token: token, remote_ip: remote_ip).call
      end
    end

    def initialize(token:, remote_ip:)
      @token = token.to_s.strip
      @remote_ip = remote_ip.to_s.strip
    end

    def call
      return BotProtection.failure_result("turnstile_token_missing") if token.blank?

      response = perform_request
      body = JSON.parse(response.body.to_s)

      return BotProtection.success_result if body["success"] == true

      BotProtection.failure_result(error_code_from(body))
    rescue JSON::ParserError
      BotProtection.failure_result("turnstile_invalid_response")
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError
      BotProtection.failure_result("turnstile_unavailable")
    end

    private

    attr_reader :token, :remote_ip

    def perform_request
      uri = URI.parse(SITEVERIFY_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data(request_payload)

      http.request(request)
    end

    def request_payload
      {
        "secret" => ENV["TURNSTILE_SECRET_KEY"].to_s,
        "response" => token
      }.tap do |payload|
        payload["remoteip"] = remote_ip if remote_ip.present?
      end
    end

    def error_code_from(body)
      code = Array(body["error-codes"]).first.to_s
      return "turnstile_verification_failed" if code.blank?

      "turnstile_#{code.tr("-", "_")}"
    end

    def timeout
      Integer(ENV.fetch("TURNSTILE_TIMEOUT", DEFAULT_TIMEOUT))
    rescue ArgumentError, TypeError
      DEFAULT_TIMEOUT
    end
  end
end
