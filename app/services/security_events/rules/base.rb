module SecurityEvents
  module Rules
    class Base
      def call(...)
        []
      end

      private

      def build_candidate(event_type:, severity:, matched_rule:, field_name:, value_excerpt:, category: nil, metadata: {})
        DetectionCandidate.new(
          event_type: event_type,
          severity: severity,
          category: category,
          matched_rule: matched_rule,
          field_name: field_name,
          value_excerpt: value_excerpt,
          metadata: metadata
        )
      end
    end
  end
end
