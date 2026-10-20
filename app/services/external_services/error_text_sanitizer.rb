module ExternalServices
  class ErrorTextSanitizer
    MAX_BYTES = 500
    MAX_DIAGNOSTIC_BYTES = 4_096
    FILTERED = "[FILTERED]".freeze
    SENSITIVE_PATTERNS = [
      /\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+\/=\-]+/i,
      /
        \b(?:(?:Ocp[ _-]*Apim[ _-]*)?subscription[ _-]*key|authorization|api[ _-]*key|
        access[ _-]*token|refresh[ _-]*token|client[ _-]*secret|secret|token|password|
        set[ _-]*cookie|cookie|session)
        ["'\s]*[:=]["'\s]*
        [^"',\s};&]+
      /ix,
      /\bsk-[A-Za-z0-9_\-]{10,}\b/i,
      /\b(?:[a-f0-9]{32}|[a-f0-9]{64})\b/i,
      /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i,
      /\bdata:[^\s"'<>]+/i,
      %r{\b[a-z][a-z0-9+.\-]*://[^\s"'<>]+}i,
      /\b[A-Za-z]:\\(?:[^\\\s"'<>]+\\)*[^\\\s"'<>]+/,
      %r{(?<![\w:])/(?:[^/\s"'<>]+/)*[^/\s"'<>]+},
      /
        \b(?:provider[_-]?raw[_-]?response|system[_-]?prompt|user[_-]?prompt|prompt|
        endpoint|operation[_-]?location)
        ["'\s]*[:=]["'\s]*
        [^\r\n;]*
      /ix
    ].freeze
    INPUT_ECHO_PATTERN = /
      \b(?:input|value|content|raw[_ -]?text|ocr[_ -]?text|receipt[_ -]?text|
      product[_ -]?name|store[_ -]?name|address|filename)
      ["'\s]*[:=]\s*(?:"[^"]*"|'[^']*'|[^\r\n;]*)
    /ix

    class << self
      def call(value, identifier: false)
        return unless value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Integer)

        text = value.to_s
        return identifier ? nil : FILTERED if text.bytesize > MAX_BYTES
        return sanitize_identifier(text) if identifier

        sanitized = text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        sanitized = sanitized.gsub(/[[:cntrl:]]/, " ").squish
        SENSITIVE_PATTERNS.each { |pattern| sanitized = sanitized.gsub(pattern, FILTERED) }
        sanitized = sanitized.gsub(INPUT_ECHO_PATTERN, FILTERED)
        return FILTERED if sanitized.bytesize > MAX_BYTES

        sanitized.presence
      rescue EncodingError
        identifier ? nil : FILTERED
      end

      def diagnostic_message(value)
        return { reason: "invalid_type" } unless value.is_a?(String)
        return { reason: "byte_limit" } if value.bytesize > MAX_DIAGNOSTIC_BYTES

        text = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        text = text.gsub(/[[:cntrl:]]/, " ").squish
        sanitized = text
        SENSITIVE_PATTERNS.each { |pattern| sanitized = sanitized.gsub(pattern, FILTERED) }
        sanitized = sanitized.gsub(INPUT_ECHO_PATTERN, FILTERED)
        return { reason: "byte_limit" } if sanitized.bytesize > MAX_DIAGNOSTIC_BYTES

        result = { value: sanitized.presence }
        result[:reason] = "redacted" if sanitized != text || sanitized.include?(FILTERED)
        result[:reason] ||= "invalid_encoding" unless value.valid_encoding?
        result.compact
      rescue EncodingError
        { reason: "invalid_encoding" }
      end

      private

      def sanitize_identifier(value)
        return unless value.valid_encoding? && value.encoding.ascii_compatible? && value.ascii_only?
        return unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.: \-]*\z/)
        return if SENSITIVE_PATTERNS.any? { |pattern| value.match?(pattern) }

        value
      end
    end
  end
end
