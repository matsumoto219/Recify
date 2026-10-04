class Ocr::ResponseParser::StoreNameEvidenceExtractor
  MAX_LINES = 10_000
  MAX_PAGES = 100
  MAX_TEXT_BYTES = 500
  MAX_TEXT_LENGTH = 255
  EDGE_LINES = 8
  DEFAULT_MAX_CANDIDATES = 10
  NUMERIC_LINE_PATTERN = /\A[\d\s\-\/:().,*＊¥￥$€£%]+\z/.freeze
  CONTROL_PATTERN = /[\u0000-\u001F\u007F]/.freeze

  def self.call(...)
    new(...).call
  end

  def initialize(analyze_result:, fields:, lines:, excluded_line_indexes:, profile:, max_candidates: DEFAULT_MAX_CANDIDATES,
    merchant_source_path: "documents[0].fields.MerchantName")
    @analyze_result = analyze_result
    @fields = fields
    @lines = lines
    @excluded_line_indexes = excluded_line_indexes
    @profile = profile
    @max_candidates = max_candidates
    @merchant_source_path = merchant_source_path
  end

  def call
    entries = line_entries
    return Analysis.store_name_evidence({}) unless entries

    merchant = merchant_candidate(entries)
    candidates = [ merchant ].compact
    selected_entries = merchant_source_entries(entries, merchant) + entries.first(EDGE_LINES) + entries.last(EDGE_LINES)
    selected_entries.uniq { |entry| entry[:candidate_id] }.each do |entry|
      next if excluded_line_indexes.include?(entry[:line_index])
      next unless possible_name?(entry[:text])

      candidates << entry
    end
    Analysis.store_name_evidence(
      { schema_version: "store_name_evidence_v1", candidates:, truncated: false, invalid: false },
      max_candidates:
    )
  end

  private

  attr_reader :analyze_result, :fields, :lines, :excluded_line_indexes, :profile, :max_candidates, :merchant_source_path

  def merchant_source_entries(entries, merchant)
    return [] unless merchant&.dig(:span_state) == "exact" && merchant[:page_index]

    entries.select do |entry|
      entry[:page_index] == merchant[:page_index] &&
        (entry[:provider_line_index] - merchant[:provider_line_index]).abs <= 1
    end
  end

  def line_entries
    pages = analyze_result["pages"]
    return fallback_entries if pages.nil? || pages == []
    return unless pages.is_a?(Array) && pages.size <= MAX_PAGES

    entries = []
    normalized_index = 0
    source_count = 0
    source_bytes = 0
    pages.each_with_index do |page, page_index|
      return unless page.is_a?(Hash) && page["lines"].is_a?(Array)
      source_count += page["lines"].size
      return if source_count > MAX_LINES

      page["lines"].each_with_index do |line, provider_line_index|
        return unless line.is_a?(Hash) && line["content"].is_a?(String)
        source_bytes += line["content"].bytesize
        return if source_bytes > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES

        source_text = normalized_text(line["content"])
        next if source_text == ""
        return if source_text.nil?

        text = name_before_phone_suffix(source_text)

        entries << {
          candidate_id: "page_#{page_index}_line_#{provider_line_index}", text:, source: "line",
          source_path: "pages[#{page_index}].lines[#{provider_line_index}]",
          line_index: normalized_index, page_index:, provider_line_index:
        }.merge(name_span_evidence(line, source_text, text))
        normalized_index += 1
      end
    end
    entries
  end

  def fallback_entries
    return unless lines.is_a?(Array) && lines.size <= MAX_LINES
    return unless lines.all?(String)
    return if lines.sum(&:bytesize) > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES

    lines.each_with_index.filter_map do |text, line_index|
      normalized = normalized_text(text)
      next if normalized.blank?

      {
        candidate_id: "line_#{line_index}", text: name_before_phone_suffix(normalized), source: "line",
        source_path: "lines[#{line_index}]", line_index:, span_state: "missing"
      }
    end
  end

  def merchant_candidate(entries)
    field = fields["MerchantName"]
    return unless field.is_a?(Hash)

    source_text = normalized_text(field["valueString"] || field["content"])
    return unless source_text.present?

    text = name_before_phone_suffix(source_text)
    return unless bounded_name?(text)
    return if text.match?(profile.store_branch_phone_suffix_pattern)

    candidate = {
      candidate_id: "merchant_name", text:, source: "merchant_name",
      source_path: merchant_source_path
    }.merge(name_span_evidence(field, source_text, text))
    confidence = field["confidence"]
    if (confidence.is_a?(Integer) || confidence.is_a?(Float)) && confidence.finite? && confidence.between?(0, 1)
      candidate[:confidence] = confidence
    end
    matching = entries.select { |entry| source_contains?(entry, candidate) }
    if matching.one?
      entry = matching.first
      return if excluded_line_indexes.include?(entry[:line_index])

      candidate.merge!(entry.slice(:line_index, :page_index, :provider_line_index))
    elsif entries.any? { |entry| excluded_line_indexes.include?(entry[:line_index]) && entry[:text] == text }
      return
    end
    candidate
  end

  def source_contains?(entry, candidate)
    return false unless entry[:span_state] == "exact" && candidate[:span_state] == "exact"

    parent = entry[:span]
    child = candidate[:span]
    parent[:offset] <= child[:offset] && parent[:offset] + parent[:length] >= child[:offset] + child[:length]
  end

  def span_evidence(value, text)
    return { span_state: "missing" } unless value.key?("spans")

    spans = value["spans"]
    return { span_state: "invalid" } unless spans.is_a?(Array) && spans.one? && spans.first.is_a?(Hash)

    span = spans.first
    offset = span["offset"]
    length = span["length"]
    maximum = Ocr::ResponseParser::AzureStringIndexMapper::MAX_PROVIDER_INDEX
    return { span_state: "invalid" } unless offset.is_a?(Integer) && offset.between?(0, maximum)
    return { span_state: "invalid" } unless length.is_a?(Integer) && length.positive?
    return { span_state: "invalid" } if length > maximum - offset
    return { span_state: "missing" } if analyze_result["stringIndexType"].nil?

    mapper = index_mapper
    return { span_state: "invalid" } unless mapper

    source = mapper.slice(provider_content, offset:, length:)
    return { span_state: "invalid" } unless normalized_text(source) == text

    { span_state: "exact", span: { offset:, length: }, string_index_type: mapper.index_type }
  end

  def name_span_evidence(value, source_text, text)
    evidence = span_evidence(value, source_text)
    return evidence if source_text == text || evidence[:span_state] != "exact"

    span = evidence[:span]
    source = index_mapper.slice(provider_content, **span)
    prefix = source.sub(profile.store_branch_phone_suffix_pattern, "").strip
    return { span_state: "missing" } unless normalized_text(prefix) == text

    source_bytes = index_mapper.byte_range_for_span(provider_content, **span)
    prefix_bytes = source.bytesize - source.lstrip.bytesize
    name_span = index_mapper.span_for_bytes(
      provider_content, byte_offset: source_bytes.begin + prefix_bytes, byte_length: prefix.bytesize
    )
    return { span_state: "missing" } unless name_span

    { span_state: "exact", span: name_span, string_index_type: index_mapper.index_type }
  end

  def name_before_phone_suffix(text)
    text.sub(profile.store_branch_phone_suffix_pattern, "").strip.presence || text
  end

  def index_mapper
    return @index_mapper if defined?(@index_mapper)

    @index_mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
  end

  def provider_content
    return @provider_content if defined?(@provider_content)

    content = analyze_result["content"]
    @provider_content = if content.is_a?(String) && content.bytesize <= Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
      content.dup.freeze
    end
  end

  def possible_name?(text)
    return false unless bounded_name?(text)
    return false if text.match?(NUMERIC_LINE_PATTERN)

    compact = text.gsub(/[[:space:]]+/, "")
    return false if compact.match?(profile.store_context_compact_noise_pattern)
    return false if text.match?(payment_line_pattern)

    noise_patterns.none? { |pattern| text.match?(pattern) }
  end

  def payment_line_pattern
    @payment_line_pattern ||= /\A(?:#{profile.ocr_payment_method_pattern})[[:space:]:：¥￥$€£\d,.-]*\z/
  end

  def noise_patterns
    @noise_patterns ||= [
      profile.ocr_store_name_noise_pattern,
      profile.store_context_noise_pattern,
      profile.store_message_line_pattern,
      profile.ai_store_greeting_noise_pattern,
      profile.store_date_time_pattern,
      profile.store_address_like_pattern,
      profile.store_heading_stop_pattern
    ]
  end

  def bounded_name?(text)
    text.bytesize <= MAX_TEXT_BYTES && text.length <= MAX_TEXT_LENGTH
  end

  def normalized_text(value)
    return unless value.is_a?(String) && value.valid_encoding?
    return unless value.encoding == Encoding::UTF_8 || value.ascii_only?
    return if value.bytesize > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
    return if value.match?(CONTROL_PATTERN)

    value.encode(Encoding::UTF_8).unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip
  end
end
