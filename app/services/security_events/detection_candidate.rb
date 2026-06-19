module SecurityEvents
  class DetectionCandidate
    attr_reader :event_type, :severity, :category, :matched_rule, :field_name, :value_excerpt, :metadata

    def initialize(event_type:, severity:, matched_rule:, field_name: nil, value_excerpt: nil, category: nil, metadata: {})
      @event_type = event_type
      @severity = severity
      @category = category
      @matched_rule = matched_rule
      @field_name = field_name
      @value_excerpt = value_excerpt
      @metadata = metadata || {}
    end

    def to_detection
      Detector::Detection.new(
        event_type: event_type,
        severity: severity,
        category: category,
        matched_rule: matched_rule,
        field_name: field_name,
        payload_excerpt: value_excerpt,
        metadata: metadata
      )
    end
  end
end
