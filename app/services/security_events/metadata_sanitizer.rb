module SecurityEvents
  class MetadataSanitizer
    MAX_ARRAY_ITEMS = 50
    MAX_HASH_ENTRIES = 100
    MAX_DEPTH = 6

    EMAIL_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
    AUTH_HEADER_PATTERN = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i
    SECRET_ASSIGNMENT_PATTERN = /
      (authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|token|password|cookie|session)
      (["'\s:=]+)
      ([^"',\s};&]+)
    /ix
    LONG_SECRET_PATTERN = /\b[A-Za-z0-9+\/=_-]{40,}\b/
    STORAGE_KEY_PATTERN = /
      blob[_-]?key|signed[_-]?id|checksum|attachment[_-]?id|active[_-]?storage[_-]?key|
      service[_-]?url|variant[_-]?url|rails[_-]?(?:blob|storage)[_-]?path
    /ix
    STORAGE_URL_PATTERN = %r{(?:/rails/active_storage/|/rails/active_storage/blobs/|/rails/active_storage/representations/)}i
    SENSITIVE_KEY_PATTERN = Regexp.union(SecurityEvent::SENSITIVE_KEY_PATTERN, STORAGE_KEY_PATTERN)

    class << self
      def call(value)
        new.call(value)
      end

      def sanitize_text(value)
        new.sanitize_text(value)
      end
    end

    def call(value)
      sanitize_value(value, depth: 0)
    end

    def sanitize_text(value)
      sanitized = value.to_s.dup
      sanitized = sanitized.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      sanitized.gsub!(EMAIL_PATTERN, "[REDACTED_EMAIL]")
      sanitized.gsub!(AUTH_HEADER_PATTERN) { "#{$1} [FILTERED]" }
      sanitized.gsub!(SECRET_ASSIGNMENT_PATTERN) { "#{$1}#{$2}[FILTERED]" }
      sanitized.gsub!(LONG_SECRET_PATTERN, "[FILTERED_SECRET]")
      sanitized = visible_control_chars(sanitized)

      truncate_bytes(sanitized, SecurityEvent::PAYLOAD_EXCERPT_MAX_BYTES)
    end

    private

    def sanitize_value(value, depth:)
      return "[TRUNCATED]" if depth > MAX_DEPTH

      case value
      when Hash
        sanitize_hash(value, depth: depth)
      when Array
        value.first(MAX_ARRAY_ITEMS).map { |child| sanitize_value(child, depth: depth + 1) }
      when String
        sanitize_metadata_text(value)
      when Symbol
        value.to_s
      when Time, Date, DateTime
        value.iso8601
      when NilClass, TrueClass, FalseClass, Numeric
        value
      else
        sanitize_metadata_text(value.to_s)
      end
    end

    def sanitize_hash(value, depth:)
      value.first(MAX_HASH_ENTRIES).each_with_object({}) do |(key, child), sanitized|
        key = key.to_s
        next if sensitive_key?(key)

        sanitized[key] = sanitize_value(child, depth: depth + 1)
      end
    end

    def sanitize_metadata_text(value)
      raw_value = value.to_s
      return if raw_value.blank?
      return "[FILTERED_STORAGE_URL]" if raw_value.match?(STORAGE_URL_PATTERN)

      sanitize_text(strip_url_secrets(raw_value))
    end

    def strip_url_secrets(value)
      uri = URI.parse(value)
      return value unless uri.is_a?(URI::HTTP)

      uri.user = nil
      uri.password = nil
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      value
    end

    def visible_control_chars(value)
      value
        .gsub("\r", "\\r")
        .gsub("\n", "\\n")
        .gsub("\t", "\\t")
        .gsub(/[[:cntrl:]]/, "")
    end

    def sensitive_key?(key)
      SENSITIVE_KEY_PATTERN.match?(key.to_s)
    end

    def truncate_bytes(value, max_bytes)
      return value if value.bytesize <= max_bytes

      value.byteslice(0, max_bytes).scrub
    end
  end
end
