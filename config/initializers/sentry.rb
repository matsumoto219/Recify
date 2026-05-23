# frozen_string_literal: true

module Recify
  module SentrySanitizer
    FILTERED = "[Filtered]"
    MAX_STRING_LENGTH = 1_024
    EMAIL_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
    SECRET_ASSIGNMENT_PATTERN = /
      (authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|token|password)
      (["'\s:=]+)
      ([^"',\s}]+)
    /ix
    AUTH_HEADER_PATTERN = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i
    OPENAI_KEY_PATTERN = /\bsk-[A-Za-z0-9_-]{10,}\b/
    LONG_SECRET_PATTERN = /\b[A-Za-z0-9+\/=_-]{40,}\b/
    SENSITIVE_KEY_PATTERN = /
      email|password|token|secret|authorization|cookie|api_key|access_token|refresh_token|
      signed_id|blob_key|active_storage_key|raw_text|\Alines\z|ocr_result|filtered_content|
      ai_raw_response|\Aprompt\z|messages|response_body|receipt_image|image|attachment|
      active_storage|blob|file|upload|arguments
    /ix

    module_function

    def sanitize_event(event)
      sanitize_event_user!(event)
      sanitize_request!(event.request) if event.respond_to?(:request) && event.request
      sanitize_event_attribute!(event, :extra)
      sanitize_event_attribute!(event, :contexts)
      sanitize_exception_values!(event)
      event.attachments = [] if event.respond_to?(:attachments=)

      event
    end

    def sanitize(value, key = nil)
      return FILTERED if sensitive_key?(key)

      case value
      when Hash
        value.each_with_object({}) do |(child_key, child_value), sanitized|
          sanitized[child_key] = sanitize(child_value, child_key)
        end
      when Array
        value.map { |item| sanitize(item) }
      when String
        sanitize_string(value)
      else
        value
      end
    end

    def sensitive_key?(key)
      normalized_key = key.to_s.downcase.tr("-", "_")
      return false if normalized_key.blank?

      normalized_key.end_with?("_key") || SENSITIVE_KEY_PATTERN.match?(normalized_key)
    end

    def sanitize_string(value)
      sanitized = value.to_s.dup
      sanitized.gsub!(EMAIL_PATTERN, FILTERED)
      sanitized.gsub!(SECRET_ASSIGNMENT_PATTERN) { "#{$1}#{$2}#{FILTERED}" }
      sanitized.gsub!(AUTH_HEADER_PATTERN) { "#{$1} #{FILTERED}" }
      sanitized.gsub!(OPENAI_KEY_PATTERN, FILTERED)
      sanitized.gsub!(LONG_SECRET_PATTERN, FILTERED)

      sanitized.length > MAX_STRING_LENGTH ? "#{sanitized[0, MAX_STRING_LENGTH]}..." : sanitized
    end

    def float_env(name, default)
      Float(ENV.fetch(name, default))
    rescue ArgumentError, TypeError
      default
    end

    def sanitize_event_user!(event)
      return unless event.respond_to?(:user) && event.respond_to?(:user=)

      user = event.user || {}
      user_id = user[:id] || user["id"] || user[:user_id] || user["user_id"]
      event.user = user_id.present? ? { id: user_id } : {}
    end

    def sanitize_event_attribute!(event, attribute)
      reader = attribute
      writer = :"#{attribute}="
      return unless event.respond_to?(reader) && event.respond_to?(writer)

      event.public_send(writer, sanitize(event.public_send(reader)))
    end

    def sanitize_request!(request)
      request.data = sanitize_request_data(request.data) if request.respond_to?(:data=)
      request.headers = sanitize(request.headers) if request.respond_to?(:headers=)
      request.cookies = sanitize(request.cookies, :cookie) if request.respond_to?(:cookies=)
      request.env = sanitize(request.env) if request.respond_to?(:env=)
      request.query_string = nil if request.respond_to?(:query_string=)
    end

    def sanitize_request_data(data)
      return if data.nil?
      return sanitize(data) if data.is_a?(Hash)

      FILTERED
    end

    def sanitize_exception_values!(event)
      return unless event.respond_to?(:exception) && event.exception&.respond_to?(:values)

      event.exception.values.each do |exception|
        exception.value = sanitize_string(exception.value) if exception.respond_to?(:value=)
      end
    end
  end
end

if Rails.env.production? && ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = ENV["SENTRY_ENVIRONMENT"].presence || Rails.env
    config.release = ENV["SENTRY_RELEASE"] if ENV["SENTRY_RELEASE"].present?

    config.send_default_pii = false
    config.include_local_variables = false
    config.breadcrumbs_logger = []
    config.sample_rate = Recify::SentrySanitizer.float_env("SENTRY_SAMPLE_RATE", 1.0)
    config.traces_sample_rate = Recify::SentrySanitizer.float_env("SENTRY_TRACES_SAMPLE_RATE", 0.0)
    config.before_send = lambda do |event, _hint|
      Recify::SentrySanitizer.sanitize_event(event)
    end
  end
end
