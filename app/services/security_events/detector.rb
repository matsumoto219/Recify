module SecurityEvents
  class Detector
    Detection = Struct.new(:event_type, :severity, :category, :matched_rule, :field_name, :payload_excerpt, :metadata, keyword_init: true)

    MAX_DETECTIONS = 5
    MAX_SCAN_VALUE_BYTES = 2_000
    MAX_DEPTH = 4
    MAX_ARRAY_ITEMS = 20
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
    PARAMETER_TAMPERING_RULE = Rules::ParameterTamperingRule.new

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
      matches.concat(PARAMETER_TAMPERING_RULE.call(param_path: field_name, value: text).map(&:to_detection))
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
      Rules::UrlRule
        .new(url_field_policy: url_field_policy)
        .call(param_path: field_name, value: text, context: { existing_matches: existing_matches })
        .map(&:to_detection)
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
