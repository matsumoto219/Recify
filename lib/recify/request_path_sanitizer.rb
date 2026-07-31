# frozen_string_literal: true

require "uri"
require_relative "active_storage_log_redactor"

module Recify
  module RequestPathSanitizer
    MAX_LENGTH = 2_048
    PROCESSING_MAX_BYTES = MAX_LENGTH * 4
    FILTERED_VALUE = "[FILTERED]"
    REDACTED_EMAIL = "[REDACTED_EMAIL]"

    EMAIL_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
    HTTP_USERINFO_PATTERN = %r{\A(https?://)[^/@\s]+@}i
    SECRET_ASSIGNMENT_PATTERN = /
      (authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|token|password|cookie|session)
      (["'\s:=]+)
      ([^"',\s};&]+)
    /ix

    module_function

    def sanitize(value, max_length: MAX_LENGTH)
      return if value.nil?

      sanitized = value.to_s.byteslice(0, PROCESSING_MAX_BYTES).to_s
      sanitized = sanitized.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      sanitized.sub!(HTTP_USERINFO_PATTERN, '\\1')
      sanitized = strip_url_secrets(sanitized)
      sanitized = ActiveStorageLogRedactor.redact(sanitized)
      sanitized.gsub!(EMAIL_PATTERN, REDACTED_EMAIL)
      sanitized.gsub!(SECRET_ASSIGNMENT_PATTERN) { "#{$1}#{$2}#{FILTERED_VALUE}" }
      sanitized = visible_control_chars(sanitized)
      sanitized = sanitized.first(max_length)
      sanitized unless sanitized.strip.empty?
    rescue EncodingError, ArgumentError, TypeError
      FILTERED_VALUE
    end

    def strip_url_secrets(value)
      uri = URI.parse(value)
      uri.user = nil if uri.respond_to?(:user=)
      uri.password = nil if uri.respond_to?(:password=)
      uri.query = nil if uri.respond_to?(:query=)
      uri.fragment = nil if uri.respond_to?(:fragment=)
      uri.to_s
    rescue URI::InvalidURIError
      value.split(/[?#]/, 2).first
    end
    private_class_method :strip_url_secrets

    def visible_control_chars(value)
      value
        .gsub("\r", "\\r")
        .gsub("\n", "\\n")
        .gsub("\t", "\\t")
        .gsub(/[[:cntrl:]]/, "")
    end
    private_class_method :visible_control_chars
  end
end
