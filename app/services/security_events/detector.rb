module SecurityEvents
  class Detector
    Detection = Struct.new(:event_type, :severity, :category, :matched_rule, :field_name, :payload_excerpt, :metadata, keyword_init: true)

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
    INPUT_RULE = Rules::InputRule.new

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
      matches = INPUT_RULE.call(param_path: field_name, value: text).map(&:to_detection)
      matches.concat(
        AI_TEXT_RULES.filter_map do |rule|
        next unless rule.fetch(:pattern).match?(text)

        build_detection(
          event_type: rule.fetch(:event_type),
          severity: rule.fetch(:severity),
          matched_rule: rule.fetch(:matched_rule),
          field_name: field_name,
          text: text
        )
      end
      )
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
      DetectionCandidate.new(
        event_type: event_type,
        severity: severity,
        category: nil,
        matched_rule: matched_rule,
        field_name: field_name,
        value_excerpt: text
      ).to_detection
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
