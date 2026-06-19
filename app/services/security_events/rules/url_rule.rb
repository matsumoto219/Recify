module SecurityEvents
  module Rules
    class UrlRule < Base
      SSRF_PATTERN = %r{https?://(?:localhost|127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|169\.254\.169\.254|metadata\.google\.internal|metadata\.azure\.com|\[::1\])}i

      def initialize(url_field_policy:)
        @url_field_policy = url_field_policy
      end

      def call(param_path:, value:, context: nil)
        unsafe_url = detect_unsafe_url(param_path, value)
        return [ unsafe_url ] if unsafe_url

        ssrf = detect_ssrf(param_path, value)
        return [ ssrf ] if ssrf
        return [] if ssrf_detected?(context)

        open_redirect = detect_open_redirect(param_path, value)
        open_redirect ? [ open_redirect ] : []
      end

      private

      attr_reader :url_field_policy

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

        build_candidate(
          event_type: "open_redirect_attempt",
          severity: "medium",
          category: "url",
          matched_rule: matched_rule,
          field_name: field_name,
          value_excerpt: text
        )
      end

      def detect_ssrf(field_name, text)
        return unless SSRF_PATTERN.match?(text)

        build_candidate(
          event_type: "ssrf_attempt",
          severity: "high",
          category: "url",
          matched_rule: "private_or_metadata_url",
          field_name: field_name,
          value_excerpt: text
        )
      end

      def detect_open_redirect(field_name, text)
        return unless url_field_policy.open_redirect_candidate?(field_name, text)
        return unless text.match?(%r{\Ahttps?://}i)
        return if text.match?(%r{\Ahttps?://(?:localhost|127\.0\.0\.1)(?::\d+)?(?:/|\z)}i)

        build_candidate(
          event_type: "open_redirect_attempt",
          severity: "medium",
          category: "url",
          matched_rule: "external_redirect_url",
          field_name: field_name,
          value_excerpt: text
        )
      end

      def ssrf_detected?(context)
        Array(context&.fetch(:existing_matches, nil)).any? do |detection|
          detection.event_type == "ssrf_attempt"
        end
      end

      def http_url_with_userinfo?(value)
        uri = URI.parse(value)
        uri.is_a?(URI::HTTP) && uri.userinfo.present?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
