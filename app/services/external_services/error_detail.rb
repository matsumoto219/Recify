module ExternalServices
  class ErrorDetail
    MAX_MESSAGE_BYTES = 500
    REQUEST_ID_HEADERS = %w[
      apim-request-id
      request-id
      x-ms-client-request-id
      x-ms-request-id
      x-request-id
      anthropic-request-id
    ].freeze
    REGION_HEADERS = %w[
      x-ms-region
    ].freeze
    RETRY_AFTER_HEADERS = %w[
      retry-after
    ].freeze
    SAFE_KEYS = %i[
      service
      provider
      phase
      http_status
      provider_error_code
      provider_message_safe
      request_id
      region
      retry_after
      latency_ms
      poll_count
      model
      rate_limited
      quota_exceeded
      auth_error
    ].freeze
    SECRET_PATTERNS = [
      /Bearer\s+[A-Za-z0-9._\-]+/i,
      /Ocp-Apim-Subscription-Key\s*[:=]\s*[A-Za-z0-9._\-]+/i,
      /\bsk-[A-Za-z0-9_\-]{10,}\b/i,
      /\b[A-Za-z0-9_\-]{24,}\b/
    ].freeze

    class << self
      def build(**attributes)
        new(**attributes).to_h
      end
    end

    def initialize(
      service: nil,
      provider: nil,
      phase: nil,
      http_status: nil,
      provider_error_code: nil,
      provider_message: nil,
      provider_message_safe: nil,
      request_id: nil,
      region: nil,
      retry_after: nil,
      latency_ms: nil,
      poll_count: nil,
      model: nil,
      rate_limited: nil,
      quota_exceeded: nil,
      auth_error: nil,
      body: nil,
      headers: nil
    )
      @attributes = {
        service: safe_string(service),
        provider: safe_string(provider),
        phase: safe_string(phase),
        http_status: safe_integer(http_status),
        provider_error_code: safe_string(provider_error_code),
        provider_message_safe: safe_message(provider_message_safe || provider_message),
        request_id: safe_string(request_id),
        region: safe_string(region),
        retry_after: safe_retry_after(retry_after),
        latency_ms: safe_numeric(latency_ms),
        poll_count: safe_integer(poll_count),
        model: safe_string(model),
        rate_limited: safe_boolean(rate_limited),
        quota_exceeded: safe_boolean(quota_exceeded),
        auth_error: safe_boolean(auth_error)
      }
      @body = body
      @headers = normalized_headers(headers)
    end

    def to_h
      body_data = body_error_data
      detail = @attributes.merge(
        provider_error_code: @attributes[:provider_error_code] || body_data[:provider_error_code],
        provider_message_safe: @attributes[:provider_message_safe] || body_data[:provider_message_safe],
        request_id: @attributes[:request_id] || header_value(REQUEST_ID_HEADERS) || body_data[:request_id],
        region: @attributes[:region] || header_value(REGION_HEADERS),
        retry_after: @attributes[:retry_after] || safe_retry_after(header_value(RETRY_AFTER_HEADERS)),
        quota_exceeded: boolean_or(@attributes[:quota_exceeded], quota_exceeded?(body_data)),
        rate_limited: boolean_or(@attributes[:rate_limited], rate_limited?(body_data)),
        auth_error: boolean_or(@attributes[:auth_error], auth_error?(body_data))
      )

      detail.slice(*SAFE_KEYS).compact
    end

    private

    def body_error_data
      parsed = parse_body(@body)
      return {} unless parsed.is_a?(Hash)

      error = normalized_hash(parsed[:error] || parsed["error"])
      source = error.presence || normalized_hash(parsed)

      code = source[:code] || source["code"] || source[:status] || source["status"] || source[:type] || source["type"]
      message = source[:message] || source["message"] || (source if source.is_a?(String))

      {
        provider_error_code: safe_string(code),
        provider_message_safe: safe_message(message),
        request_id: safe_string(parsed[:request_id] || parsed["request_id"])
      }.compact
    end

    def parse_body(value)
      return value if value.is_a?(Hash)
      return {} if value.blank?

      JSON.parse(value.to_s)
    rescue JSON::ParserError, TypeError
      { message: value.to_s }
    end

    def normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)
      return { message: value.to_s }.with_indifferent_access if value.is_a?(String)

      {}.with_indifferent_access
    end

    def normalized_headers(value)
      return {} unless value.respond_to?(:each)

      value.each_with_object({}) do |(key, header_value), memo|
        memo[key.to_s.downcase] = header_value.to_s
      end
    end

    def header_value(keys)
      keys.lazy.map { |key| @headers[key] }.find { |value| value.present? }
    end

    def quota_exceeded?(data)
      text = classification_text(data)
      text.match?(/quota|insufficient_quota|call volume|resource_exhausted|exceeded/i)
    end

    def rate_limited?(data)
      status = @attributes[:http_status]
      return true if status == 429

      classification_text(data).match?(/rate[_ -]?limit|too many requests/i)
    end

    def auth_error?(data)
      status = @attributes[:http_status]
      return false if quota_exceeded?(data)
      return true if status == 401

      status == 403 && classification_text(data).match?(/auth|api[_ -]?key|credential|permission|forbidden|unauthorized/i)
    end

    def classification_text(data)
      [
        data[:provider_error_code],
        data[:provider_message_safe]
      ].compact.join(" ")
    end

    def boolean_or(left, right)
      return true if left == true || right == true
      return false if left == false

      nil
    end

    def safe_message(value)
      sanitized = safe_string(value)
      return if sanitized.blank?

      SECRET_PATTERNS.each do |pattern|
        sanitized = sanitized.gsub(pattern, "[FILTERED]")
      end

      truncate_bytes(sanitized, MAX_MESSAGE_BYTES)
    end

    def safe_string(value)
      value.to_s.presence if value.present?
    end

    def safe_integer(value)
      return value if value.is_a?(Integer)
      return value.to_i if value.to_s.match?(/\A-?\d+\z/)

      nil
    end

    def safe_numeric(value)
      return value if value.is_a?(Numeric)
      return value.to_f if value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)

      nil
    end

    def safe_retry_after(value)
      numeric = safe_numeric(value)
      return numeric if numeric && numeric >= 0
      return if value.blank?

      delay = Time.httpdate(value.to_s) - Time.current
      delay.negative? ? nil : delay
    rescue ArgumentError, TypeError
      nil
    end

    def safe_boolean(value)
      return true if value == true
      return false if value == false

      nil
    end

    def truncate_bytes(value, max_bytes)
      return value if value.bytesize <= max_bytes

      value.byteslice(0, max_bytes).to_s.scrub
    end
  end
end
