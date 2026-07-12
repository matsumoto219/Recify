class Ocr::ResponseParser::StructuredSourceMetadataExtractor
  def initialize(pages:, text_normalizer:)
    @pages = pages
    @text_normalizer = text_normalizer
  end

  def call(field:, field_path:)
    return {} unless field.is_a?(Hash)

    metadata = {
      source_provider: "azure_structured",
      source_field_path: field_path
    }
    line_entry = source_line_entry(field)
    return metadata unless line_entry

    metadata[:source_line_index] = line_entry[:line_index]
    local_span = local_span(field, line_entry)
    if local_span
      metadata[:source_span_start] = local_span.begin
      metadata[:source_span_end] = local_span.end
    end
    metadata
  end

  private

  def source_line_entry(field)
    field_span = normalized_provider_span(Array(field["spans"]).first)
    if field_span
      matching_line = line_entries.find do |line|
        line[:provider_spans].any? { |line_span| provider_spans_overlap?(line_span, field_span) }
      end
      return matching_line if matching_line
    end

    field_content = normalize_text(field["content"])
    return if field_content.blank?

    line_entries.find do |line|
      line[:normalized_text].include?(field_content)
    end
  end

  def line_entries
    @line_entries ||= Array(@pages).flat_map do |page|
      Array(page["lines"])
    end.each_with_object([]) do |line, result|
      normalized_text = normalize_text(line["content"])
      next if normalized_text.blank?

      result << {
        line_index: result.length,
        normalized_text: normalized_text,
        provider_spans: Array(line["spans"]).filter_map { |span| normalized_provider_span(span) }
      }
    end
  end

  def local_span(field, line_entry)
    field_content = normalize_text(field["content"])
    if field_content.present?
      start_index = line_entry[:normalized_text].index(field_content)
      return (start_index...(start_index + field_content.length)) if start_index
    end

    field_span = normalized_provider_span(Array(field["spans"]).first)
    line_span = line_entry[:provider_spans].find { |span| provider_spans_overlap?(span, field_span) }
    return unless field_span && line_span

    start_index = [ field_span.begin - line_span.begin, 0 ].max
    end_index = [ field_span.end - line_span.begin, line_entry[:normalized_text].length ].min
    return unless end_index > start_index

    (start_index...end_index)
  end

  def normalized_provider_span(value)
    return unless value.is_a?(Hash)

    offset = Integer(value["offset"], exception: false)
    length = Integer(value["length"], exception: false)
    return unless offset && length&.positive?

    (offset...(offset + length))
  end

  def provider_spans_overlap?(left, right)
    left && right && left.begin < right.end && right.begin < left.end
  end

  def normalize_text(value)
    @text_normalizer.call(value)
  end
end
