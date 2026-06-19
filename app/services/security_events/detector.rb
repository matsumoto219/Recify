module SecurityEvents
  class Detector
    Detection = Struct.new(:event_type, :severity, :matched_rule, :field_name, :payload_excerpt, keyword_init: true)

    MAX_DETECTIONS = 5
    MAX_SCAN_VALUE_BYTES = 2_000
    MAX_DEPTH = 4
    MAX_ARRAY_ITEMS = 20
    PROTECTED_RECEIPT_FIELDS = %w[
      id
      user_id
      receipt_id
      public_id
      display_id
      status
      processing_error_code
      processing_error_message
      keep_image
      image_purged_at
      image_purged_reason
    ].freeze
    PROTECTED_USER_FIELDS = %w[
      id
      admin
      role
      guest
      confirmed_at
      locked_at
      failed_attempts
      session_version
      user_limit
      storage_bytes_used
    ].freeze
    SENSITIVE_KEY_PATTERN = /
      password|token|authorization|cookie|secret|api[_-]?key|access[_-]?token|
      refresh[_-]?token|totp|otp|recovery[_-]?code|backup[_-]?code|csrf|
      session|credential|challenge|raw[_-]?response|prompt|raw[_-]?text
    /ix

    INPUT_RULES = [
      {
        event_type: "sql_injection_attempt",
        severity: "high",
        matched_rule: "sql_union_or_tautology",
        pattern: /(?:\bunion\s+select\b|\bor\s+1\s*=\s*1\b|\band\s+1\s*=\s*1\b|'\s*or\s*'1'\s*=\s*'1)/i
      },
      {
        event_type: "sql_injection_attempt",
        severity: "high",
        matched_rule: "sql_destructive_statement",
        pattern: /(?:;\s*)?\b(?:drop|alter|truncate)\s+(?:table|database)\b/i
      },
      {
        event_type: "nosql_injection_attempt",
        severity: "medium",
        matched_rule: "nosql_operator_marker",
        pattern: /(?:["']?\$(?:ne|gt|gte|lt|lte|in|nin|where|regex)["']?\s*:|\b\$where\b)/i
      },
      {
        event_type: "xss_attempt",
        severity: "high",
        matched_rule: "script_or_javascript",
        pattern: /(?:<\s*script\b|javascript\s*:|on(?:error|load|click|mouseover)\s*=)/i
      },
      {
        event_type: "html_injection_attempt",
        severity: "medium",
        matched_rule: "active_html_element",
        pattern: /<\s*(?:iframe|object|embed|svg|meta|link|style)\b/i
      },
      {
        event_type: "path_traversal_attempt",
        severity: "high",
        matched_rule: "dot_dot_path",
        pattern: /(?:\.\.\/|\.\.\\|%2e%2e|%252e%252e|%2fetc%2fpasswd|\/etc\/passwd)/i
      },
      {
        event_type: "ssrf_attempt",
        severity: "high",
        matched_rule: "private_or_metadata_url",
        pattern: %r{https?://(?:localhost|127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|169\.254\.169\.254|metadata\.google\.internal|metadata\.azure\.com|\[::1\])}i
      },
      {
        event_type: "crlf_injection_attempt",
        severity: "medium",
        matched_rule: "encoded_or_literal_crlf_header",
        pattern: /(?:%0d%0a|\r\n|\n(?:set-cookie|location|content-length)\s*:)/i
      },
      {
        event_type: "command_injection_attempt",
        severity: "high",
        matched_rule: "shell_metachar_or_command",
        pattern: /(?:[`|;&]\s*(?:curl|wget|bash|sh|powershell|cmd\.exe)\b|\$\([^)]{1,100}\))/i
      },
      {
        event_type: "log_injection_attempt",
        severity: "low",
        matched_rule: "log_line_breakout",
        pattern: /(?:\r|\n)(?:\s*(?:error|warn|fatal|info)\b|\[[A-Z]+\])/i
      },
      {
        event_type: "template_injection_attempt",
        severity: "medium",
        matched_rule: "template_expression_marker",
        pattern: /(?:\{\{[^}]{1,120}\}\}|\{%[^%]{1,120}%\}|<%=?[^%]{1,120}%>)/i
      },
      {
        event_type: "redos_attempt",
        severity: "medium",
        matched_rule: "nested_quantifier_regex",
        pattern: /\((?:[^()]{1,40}[+*])\)[+*]/
      },
      {
        event_type: "csv_injection_attempt",
        severity: "medium",
        matched_rule: "spreadsheet_formula_marker",
        pattern: /\A[=+@]\s*(?:cmd|powershell|hyperlink|importxml|importdata|webservice|[A-Z]+\s*\()/i
      },
      {
        event_type: "xml_injection_attempt",
        severity: "medium",
        matched_rule: "xml_doctype_or_entity",
        pattern: /(?:<!DOCTYPE\b|<!ENTITY\b|<\?xml\b.{0,200}<!DOCTYPE\b)/im
      },
      {
        event_type: "xpath_injection_attempt",
        severity: "medium",
        matched_rule: "xpath_boolean_bypass",
        pattern: /(?:\bor\s+count\s*\(|\bor\s+name\s*\(|\]\s*\[|\bor\s+['"]1['"]\s*=\s*['"]1['"])/i
      },
      {
        event_type: "ldap_injection_attempt",
        severity: "medium",
        matched_rule: "ldap_filter_breakout",
        pattern: /(?:\*\)\s*\(|\(\|\s*\([^)]*\*\)|\(\&\s*\([^)]*\*\))/
      },
      {
        event_type: "schema_abuse_attempt",
        severity: "medium",
        matched_rule: "json_schema_control_key",
        pattern: /["'](?:__proto__|constructor|prototype|\$schema|\$ref)["']\s*:/i
      }
    ].freeze

    AI_TEXT_RULES = [
      {
        event_type: "prompt_injection_attempt",
        severity: "medium",
        matched_rule: "prompt_override_marker",
        pattern: /(?:ignore (?:all )?(?:previous|prior) instructions|system prompt|developer message|you are now|jailbreak|prompt injection)/i
      },
      {
        event_type: "ocr_text_injection_attempt",
        severity: "medium",
        matched_rule: "receipt_instruction_marker",
        pattern: /(?:ignore receipt|override total|do not trust|ai instruction|assistant:|system:)/i
      }
    ].freeze
    RULES = (INPUT_RULES + AI_TEXT_RULES).freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(params:, max_detections: MAX_DETECTIONS, url_field_policy: UrlFieldPolicy.new)
      @params = params
      @max_detections = max_detections.to_i.positive? ? max_detections.to_i : MAX_DETECTIONS
      @url_field_policy = url_field_policy || UrlFieldPolicy.new
    end

    def call
      detections = []

      each_string(params) do |field_name, value|
        detect_value(field_name, value).each do |detection|
          detections << detection
          return detections if detections.size >= max_detections
        end
      end

      detections
    end

    private

    attr_reader :params, :max_detections, :url_field_policy

    def detect_value(field_name, value)
      return [] if value.blank?

      text = scan_text(value)
      matches = detect_rule_matches(field_name, text)
      matches.concat(detect_url_matches(field_name, text, matches))
      parameter_tampering = detect_parameter_tampering(field_name, text)
      matches << parameter_tampering if parameter_tampering
      matches
    end

    def detect_rule_matches(field_name, text)
      RULES.filter_map do |rule|
        next unless rule.fetch(:pattern).match?(text)

        build_detection(
          event_type: rule.fetch(:event_type),
          severity: rule.fetch(:severity),
          matched_rule: rule.fetch(:matched_rule),
          field_name: field_name,
          text: text
        )
      end
    end

    def detect_url_matches(field_name, text, existing_matches)
      unsafe_url = detect_unsafe_url(field_name, text)
      return [ unsafe_url ] if unsafe_url
      return [] if ssrf_detected?(existing_matches)

      open_redirect = detect_open_redirect(field_name, text)
      open_redirect ? [ open_redirect ] : []
    end

    def ssrf_detected?(matches)
      matches.any? { |detection| detection.event_type == "ssrf_attempt" }
    end

    def detect_unsafe_url(field_name, text)
      return unless url_field_policy.url_field?(field_name)

      value = text.to_s.strip
      matched_rule =
        if value.match?(/\A(?:data|file|vbscript):/i)
          "forbidden_url_scheme"
        elsif value.start_with?("//")
          "protocol_relative_url"
        elsif value.include?("\\")
          "backslash_url"
        elsif value.match?(/[\r\n\u0000]/)
          "control_character_url"
        elsif http_url_with_userinfo?(value)
          "userinfo_url"
        end
      return unless matched_rule

      build_detection(
        event_type: "open_redirect_attempt",
        severity: "medium",
        matched_rule: matched_rule,
        field_name: field_name,
        text: text
      )
    end

    def detect_open_redirect(field_name, text)
      return unless url_field_policy.open_redirect_candidate?(field_name, text)
      return unless text.match?(%r{\Ahttps?://}i)
      return if text.match?(%r{\Ahttps?://(?:localhost|127\.0\.0\.1)(?::\d+)?(?:/|\z)}i)

      build_detection(
        event_type: "open_redirect_attempt",
        severity: "medium",
        matched_rule: "external_redirect_url",
        field_name: field_name,
        text: text
      )
    end

    def http_url_with_userinfo?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && uri.userinfo.present?
    rescue URI::InvalidURIError
      false
    end

    def detect_parameter_tampering(field_name, text)
      segments = field_name.to_s.split(".")
      matched_rule =
        if segments.first == "receipt" && (segments & PROTECTED_RECEIPT_FIELDS).any?
          "protected_receipt_attribute"
        elsif segments.first == "user" && (segments & PROTECTED_USER_FIELDS).any?
          "protected_user_attribute"
        end

      return unless matched_rule

      build_detection(
        event_type: "parameter_tampering_attempt",
        severity: "medium",
        matched_rule: matched_rule,
        field_name: field_name,
        text: text
      )
    end

    def build_detection(event_type:, severity:, matched_rule:, field_name:, text:)
      Detection.new(
        event_type: event_type,
        severity: severity,
        matched_rule: matched_rule,
        field_name: field_name,
        payload_excerpt: text
      )
    end

    def each_string(value, prefix = nil, depth = 0, &block)
      return if depth > MAX_DEPTH

      return if uploaded_file?(value)

      case value
      when ActionDispatch::Http::UploadedFile
        nil
      when Hash, ActionController::Parameters
        child_values = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
        child_values.each do |key, child|
          key = key.to_s
          next if sensitive_key?(key)

          child_prefix = prefix.present? ? "#{prefix}.#{key}" : key
          each_string(child, child_prefix, depth + 1, &block)
        end
      when Array
        value.first(MAX_ARRAY_ITEMS).each_with_index do |child, index|
          child_prefix = prefix.present? ? "#{prefix}[#{index}]" : index.to_s
          each_string(child, child_prefix, depth + 1, &block)
        end
      when String, Symbol, Numeric
        block.call(prefix, value.to_s) if prefix.present?
      end
    end

    def scan_text(value)
      text = value.to_s
      return "" unless text.valid_encoding?

      truncate_bytes(text, MAX_SCAN_VALUE_BYTES)
    end

    def sensitive_key?(key)
      SENSITIVE_KEY_PATTERN.match?(key.to_s)
    end

    def uploaded_file?(value)
      return true if value.is_a?(ActionDispatch::Http::UploadedFile)
      return false unless defined?(Rack::Test::UploadedFile)

      value.is_a?(Rack::Test::UploadedFile)
    end

    def truncate_bytes(value, max_bytes)
      return value if value.bytesize <= max_bytes

      value.byteslice(0, max_bytes).scrub
    end
  end
end
