module Analysis
  class SourceEvidenceAttributeExtractor
    ATTRIBUTE_KEYS = %i[
      source_provider
      source_field_path
      source_line_index
      source_span_start
      source_span_end
    ].freeze

    def self.call(value)
      normalized = value.respond_to?(:to_h) ? value.to_h.with_indifferent_access : {}.with_indifferent_access

      normalized.slice(*ATTRIBUTE_KEYS).compact.to_h.symbolize_keys
    end
  end
end
