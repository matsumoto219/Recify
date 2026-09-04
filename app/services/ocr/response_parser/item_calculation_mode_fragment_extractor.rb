class Ocr::ResponseParser::ItemCalculationModeFragmentExtractor
  MAX_LINES = 150
  MAX_WORDS = 4_800
  MAX_ITEMS = 100
  MAX_FIELD_ENTRIES = 100
  MAX_FIELD_DEPTH = 4
  MAX_FIELD_NODES = 1_600
  MAX_PARENT_SPANS = 4
  MAX_FIELD_BYTES = 4_096
  MAX_CONTENT_BYTES = Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  MAX_LINE_CONTENT_BYTES = 512
  MAX_WORD_CONTENT_BYTES = 64
  MAX_NAME_BYTES = 96
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  MAX_PAGE_DIMENSION = 10_000
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  SOURCE_KIND = "azure_calculation_layout"
  VALIDATION_CONTRACT_VERSION = "azure_calculation_layout_v1"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze

  def self.call(analyze_result:, profile:)
    new(analyze_result:, profile:).call
  end

  def initialize(analyze_result:, profile:)
    @analyze_result = analyze_result
    @profile = profile
  end

  def call
    return [] unless prepare_context

    owners = lines.map { [] }
    structured_items.each_with_index do |item, index|
      spans = item_spans(item)
      return [] if spans.nil?

      spans.each do |span|
        line_index = lines.bsearch_index { |line| line[:span_end] > span[:span_start] }
        next if line_index.nil?

        while line_index < lines.size && lines[line_index][:span_start] < span[:span_end]
          owners[line_index] << index unless owners[line_index].include?(index)
          line_index += 1
        end
      end
    end
    lines.filter_map do |line|
      indexes = owners[line[:index]]
      next unless indexes.size == 2
      next if non_item_spans.any? { |span| overlap?(span, line) }

      descriptor(line, indexes)
    end.sort_by { |entry| entry[:structured_item_index] }
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    []
  end

  private

  attr_reader :analyze_result, :profile, :mapper, :content, :page, :lines, :structured_items, :non_item_spans

  def prepare_context
    return false unless profile.respond_to?(:ocr_reference_pricing_line_group_destination_identifier_conflict_patterns)
    return false unless profile.respond_to?(:ocr_item_calculation_fragment_name_prefix_pattern)
    return false unless analyze_result.is_a?(Hash)
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID && analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    @content = bounded_text(analyze_result["content"], MAX_CONTENT_BYTES)
    return false if mapper.nil? || content.nil?

    @content = content.dup.freeze

    pages = analyze_result["pages"]
    documents = analyze_result["documents"]
    return false unless pages.is_a?(Array) && pages.one? && documents.is_a?(Array) && documents.one?

    @page = pages.sole
    return false unless page.is_a?(Hash) && page["pageNumber"] == 1 && page["unit"] == "pixel"
    return false unless [ page["width"], page["height"] ].all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? && value <= MAX_PAGE_DIMENSION }

    fields = documents.sole.is_a?(Hash) && documents.sole["fields"]
    return false unless fields.is_a?(Hash) && fields.size <= MAX_FIELD_ENTRIES

    @structured_items = fields.dig("Items", "valueArray")
    return false unless structured_items.is_a?(Array) && structured_items.size.between?(2, MAX_ITEMS)

    @non_item_spans = []
    @field_nodes = 0
    return false unless fields.except("Items").values.all? { |field| collect_non_item_spans(field, depth: 0) }

    prepare_lines && prepare_words
  end

  def prepare_lines
    entries = page["lines"]
    return false unless entries.is_a?(Array) && entries.size.between?(1, MAX_LINES)

    @lines = entries.map.with_index { |entry, index| layout_entry(entry, index:, word: false) }
    return false if lines.any?(&:nil?)

    lines.each_cons(2).all? { |left, right| left[:span_end] <= right[:span_start] }
  end

  def prepare_words
    entries = page["words"]
    return false unless entries.is_a?(Array) && entries.size.between?(1, MAX_WORDS)

    words = entries.map.with_index { |entry, index| layout_entry(entry, index:, word: true) }
    return false if words.any?(&:nil?)
    return false unless words.each_cons(2).all? { |left, right| left[:span_end] <= right[:span_start] }

    line_index = 0
    words.all? do |word|
      while line_index < lines.size && word[:span_start] >= lines[line_index][:span_end]
        line_index += 1
      end
      line = lines[line_index]
      next false unless line && within?(word, line) && polygon_within?(word[:bounds], line[:bounds])

      line[:words] << word
      true
    end
  end

  def layout_entry(entry, index:, word:)
    return unless entry.is_a?(Hash)

    text = bounded_text(entry["content"], word ? MAX_WORD_CONTENT_BYTES : MAX_LINE_CONTENT_BYTES)
    return if text.blank? || text.match?(/[\r\n\u0085\u2028\u2029]/)

    span = word ? valid_span(entry["span"]) : single_span(entry)
    return unless span && exact_text?(text, span)

    bounds = polygon_bounds(entry["polygon"])
    return if bounds.nil?

    span.merge(content: text, bounds:, index:, words: [])
  end

  def descriptor(line, indexes)
    fields = indexes.map { |index| structured_items[index]["valueObject"] }
    return unless fields.all? { |entry| entry.is_a?(Hash) && entry.one? }

    name_position = fields.index { |entry| entry.keys == [ "Description" ] }
    total_position = fields.index { |entry| entry.keys == [ "TotalPrice" ] }
    return if name_position.nil? || total_position.nil?
    return unless covered?(line, line[:words])

    name_index = indexes[name_position]
    total_index = indexes[total_position]
    return unless complementary_parents?(line, name_index:, total_index:)

    name = field_entry(structured_items[name_index], "Description", line)
    total = field_entry(structured_items[total_index], "TotalPrice", line)
    return if name.nil? || total.nil? || !separated?(name, total)
    return unless whitespace?(name[:span_end], total[:span_start]) && whitespace?(total[:span_end], line[:span_end])
    return unless product_name?(name[:content]) && fields[name_position]["Description"]["valueString"] == name[:content]

    amount = exact_amount(fields[total_position]["TotalPrice"])
    return if amount.nil?

    build_descriptor(line, name:, total:, name_index:, total_index:, amount:)
  end

  def complementary_parents?(line, name_index:, total_index:)
    name = single_span(structured_items[name_index])
    total = single_span(structured_items[total_index])
    return false if name.nil? || total.nil? || overlap?(name, total)

    whitespace?(line[:span_start], name[:span_start]) &&
      whitespace?(name[:span_end], total[:span_start]) && whitespace?(total[:span_end], line[:span_end])
  end

  def build_descriptor(line, name:, total:, name_index:, total_index:, amount:)
    identity = "azure_calculation_layout_p0_name_l#{line[:index]}_s#{name[:span_start]}_e#{name[:span_end]}_block_e#{total[:span_end]}"
    {
      source_provider: SOURCE_KIND,
      validation_contract_version: VALIDATION_CONTRACT_VERSION,
      source_field_path: "pages[0].lines[#{line[:index]}]",
      item_identity: identity,
      structured_item_index: name_index,
      structured_item_indexes: [ name_index, total_index ].sort,
      total_item_index: total_index,
      block_provider_span_start: name[:span_start],
      block_provider_span_end: total[:span_end],
      owned_line_indexes: [ line[:index] ],
      destination_evidence: evidence(name, line),
      options: [
        {
          pricing_source_kind: "explicit_line_total",
          source: { line_total_amount: amount.to_s },
          evidence: { line_total: evidence(total, line) }
        }
      ],
      printed_line_total: amount.to_s,
      layout_item: {
        name: name[:content],
        price: nil,
        quantity: nil,
        quantity_unit_code: nil,
        line_total: amount,
        ocr_item_identity: identity
      }
    }
  end

  def field_entry(item, field_name, line)
    parent = single_span(item)
    parent_text = bounded_text(item["content"], MAX_FIELD_BYTES)
    parent_bounds = field_bounds(item)
    return unless parent && parent_text && exact_text?(parent_text, parent) && parent_bounds && within?(parent, line)
    return unless polygon_within?(parent_bounds, line[:bounds])

    field = item["valueObject"][field_name]
    return unless field.is_a?(Hash)

    span = single_span(field)
    text = bounded_text(field["content"], MAX_FIELD_BYTES)
    bounds = field_bounds(field)
    return unless span && text && bounds && exact_text?(text, span) && within?(span, parent)
    return unless polygon_within?(bounds, parent_bounds) && polygon_within?(bounds, line[:bounds])
    return unless field_wrapper_valid?(field_name, span:, parent:)

    words = line[:words].select { |word| overlap?(word, span) }
    return unless covered?(span, words) && words.all? { |word| polygon_within?(word[:bounds], bounds) }

    span.merge(content: text, bounds:, words:)
  end

  def field_wrapper_valid?(field_name, span:, parent:)
    return false unless whitespace?(span[:span_end], parent[:span_end])
    return true if whitespace?(parent[:span_start], span[:span_start])
    return false unless field_name == "Description"

    prefix = mapper.slice(content, offset: parent[:span_start], length: span[:span_start] - parent[:span_start])
    prefix&.match?(profile.ocr_item_calculation_fragment_name_prefix_pattern)
  end

  def exact_amount(field)
    currency = field["valueCurrency"]
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"
    return unless currency["currencySymbol"].nil? || currency["currencySymbol"] == "¥"

    match = Ocr::ResponseParser::ItemCalculationModeCandidateExtractor::MONEY_CONTENT_PATTERN.match(field["content"].unicode_normalize(:nfkc))
    return if match.nil? || match[:amount].bytesize > 32

    value = currency["amount"]
    return unless value.is_a?(Numeric) && value.finite? && value.to_s.bytesize <= 32

    amount = BigDecimal(match[:amount].delete(","))
    return unless amount == BigDecimal(value.to_s) && amount.frac.zero? && amount.between?(0, 999_999_999_999)

    amount.to_i
  end

  def product_name?(text)
    text.bytesize <= MAX_NAME_BYTES && text.match?(/[\p{L}\p{N}]/u) &&
      profile.ocr_reference_pricing_line_group_destination_identifier_conflict_patterns.none? { |pattern| text.match?(pattern) }
  end

  def separated?(name, total)
    name[:span_end] <= total[:span_start] && name[:bounds][:right] <= total[:bounds][:left] &&
      name[:bounds][:top] < total[:bounds][:bottom] && total[:bounds][:top] < name[:bounds][:bottom]
  end

  def evidence(component, line)
    {
      source_field_path: "pages[0].lines[#{line[:index]}]",
      page_index: 0,
      line_index: line[:index],
      provider_span_start: component[:span_start],
      provider_span_end: component[:span_end],
      word_spans: component[:words].map do |word|
        {
          word_index: word[:index],
          provider_span_start: word[:span_start],
          provider_span_end: word[:span_end]
        }
      end
    }
  end

  def collect_non_item_spans(field, depth:)
    @field_nodes += 1
    return false if depth > MAX_FIELD_DEPTH || @field_nodes > MAX_FIELD_NODES
    return false unless field.is_a?(Hash) && field.size <= MAX_FIELD_ENTRIES

    if field.key?("spans")
      spans = item_spans(field)
      return false if spans.nil?

      non_item_spans.concat(spans)
    end
    object = field["valueObject"]
    array = field["valueArray"]
    return false unless object.nil? || (object.is_a?(Hash) && object.size <= MAX_FIELD_ENTRIES && object.values.all? { |child| collect_non_item_spans(child, depth: depth + 1) })
    return false unless array.nil? || (array.is_a?(Array) && array.size <= MAX_FIELD_ENTRIES && array.all? { |child| collect_non_item_spans(child, depth: depth + 1) })

    true
  end

  def item_spans(item)
    return unless item.is_a?(Hash)

    values = item["spans"]
    return unless values.is_a?(Array) && values.size.between?(1, MAX_PARENT_SPANS)

    spans = values.map { |value| valid_span(value) }
    return if spans.any?(&:nil?)
    return unless spans.each_cons(2).all? { |left, right| left[:span_end] <= right[:span_start] }

    spans
  end

  def single_span(entry)
    spans = item_spans(entry)
    spans.sole if spans&.one?
  end

  def valid_span(value)
    return unless value.is_a?(Hash)

    offset = value["offset"]
    length = value["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length.positive?
    return if offset > MAX_PROVIDER_SPAN_VALUE || length > MAX_PROVIDER_SPAN_VALUE - offset
    return if mapper.slice(content, offset:, length:).nil?

    { span_start: offset, span_end: offset + length }
  end

  def exact_text?(text, span)
    mapper.slice(content, offset: span[:span_start], length: span[:span_end] - span[:span_start]) == text
  end

  def bounded_text(value, limit)
    return unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= limit
    return if value.match?(CONTROL_CHARACTER_PATTERN)

    value
  end

  def covered?(span, words)
    return false if words.empty? || words.first[:span_start] != span[:span_start] || words.last[:span_end] != span[:span_end]

    words.all? { |word| within?(word, span) } && words.each_cons(2).all? { |left, right| whitespace?(left[:span_end], right[:span_start]) }
  end

  def whitespace?(start, finish)
    finish >= start && mapper.slice(content, offset: start, length: finish - start)&.match?(/\A[ \t]*\z/)
  end

  def within?(inner, outer)
    inner[:span_start] >= outer[:span_start] && inner[:span_end] <= outer[:span_end]
  end

  def overlap?(left, right)
    left[:span_start] < right[:span_end] && right[:span_start] < left[:span_end]
  end

  def field_bounds(field)
    regions = field["boundingRegions"]
    return unless regions.is_a?(Array) && regions.one? && regions.sole.is_a?(Hash) && regions.sole["pageNumber"] == 1

    polygon_bounds(regions.sole["polygon"])
  end

  def polygon_bounds(polygon)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |value| value.is_a?(Numeric) && value.finite? }
    return unless polygon.each_slice(2).all? { |x, y| x.between?(0, page["width"]) && y.between?(0, page["height"]) }

    points = polygon.each_slice(2).map { |pair| pair.map { |value| Rational(value.to_s) } }

    crosses = 4.times.map do |index|
      first = points[index]
      second = points[(index + 1) % 4]
      third = points[(index + 2) % 4]
      (second[0] - first[0]) * (third[1] - second[1]) -
        (second[1] - first[1]) * (third[0] - second[0])
    end
    return unless crosses.all?(&:positive?) || crosses.all?(&:negative?)

    left, right = points.map(&:first).minmax
    top, bottom = points.map(&:last).minmax
    { left:, right:, top:, bottom: }
  end

  def polygon_within?(inner, outer)
    inner[:left] >= outer[:left] - 1 && inner[:right] <= outer[:right] + 1 &&
      inner[:top] >= outer[:top] - 1 && inner[:bottom] <= outer[:bottom] + 1
  end
end
