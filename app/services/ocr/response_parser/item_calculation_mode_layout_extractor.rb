class Ocr::ResponseParser::ItemCalculationModeLayoutExtractor
  MAX_LINES = 150
  MAX_WORDS = 4_800
  MAX_ITEMS = 100
  MAX_DOCUMENT_FIELDS = 100
  MAX_FIELD_ENTRIES = 16
  MAX_PARENT_SPANS = 4
  MAX_FIELD_BYTES = 4_096
  STRUCTURED_FIELD_NAMES = %w[Description Price Quantity QuantityUnit TotalPrice].freeze
  MAX_CONTENT_BYTES = Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  MAX_LINE_CONTENT_BYTES = 512
  MAX_WORD_CONTENT_BYTES = 64
  MAX_NAME_BYTES = 96
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  MAX_PAGE_DIMENSION = 10_000
  MAX_VERTICAL_GAP_RATIO = Rational(1, 2)
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  SOURCE_KIND = "azure_calculation_layout"
  VALIDATION_CONTRACT_VERSION = "azure_calculation_layout_v1"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  DECIMAL_PATTERN = /\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/.freeze

  def self.call(analyze_result:, profile:)
    new(analyze_result:, profile:).call
  end

  def initialize(analyze_result:, profile:)
    @analyze_result = analyze_result
    @profile = profile
  end

  def call
    return [] unless prepare_context

    descriptors = []
    owned = Array.new(lines.size, false)
    @fragment_components = {}
    lines.each_with_index do |line, index|
      next if owned[index]

      descriptor = descriptor_at(line, index:, owned:)
      next if descriptor.nil?

      descriptors << descriptor
      descriptor[:owned_line_indexes].each { |line_index| owned[line_index] = true }
    end
    return [] if descriptors.size > MAX_ITEMS
    return [] unless complete_item_region?(owned)
    return [] unless associate_structured_fragments(descriptors)

    descriptors
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    []
  end

  private

  attr_reader :analyze_result, :profile, :mapper, :content, :lines, :fields, :structured_items

  def prepare_context
    return false unless profile.respond_to?(:ocr_item_calculation_layout_price_line_pattern)
    return false unless analyze_result.is_a?(Hash)
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return false unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    @content = bounded_text(analyze_result["content"], MAX_CONTENT_BYTES)
    return false if mapper.nil? || content.nil?

    pages = analyze_result["pages"]
    documents = analyze_result["documents"]
    return false unless pages.is_a?(Array) && pages.one?
    return false unless documents.is_a?(Array) && documents.one?

    @fields = documents.sole.is_a?(Hash) && documents.sole["fields"]
    return false unless fields.is_a?(Hash) && fields.size <= MAX_DOCUMENT_FIELDS
    return false unless prepare_non_item_spans

    items = fields["Items"]
    return false unless items.nil? || items.is_a?(Hash)

    @structured_items = items&.fetch("valueArray", nil)
    @structured_items = [] if structured_items.nil?
    return false unless structured_items.is_a?(Array) && structured_items.size <= MAX_ITEMS
    return false unless structured_items.all?(Hash)

    @lines = validated_lines(pages.sole)
    lines.present? && validate_words(pages.sole)
  end

  def validated_lines(page)
    return unless page.is_a?(Hash) && page["unit"] == "pixel" && page["pageNumber"] == 1
    return unless [ page["width"], page["height"] ].all? do |value|
      value.is_a?(Numeric) && value.finite? && value.positive? && value <= MAX_PAGE_DIMENSION
    end

    entries = page["lines"]
    return unless entries.is_a?(Array) && entries.size.between?(2, MAX_LINES)

    result = entries.map.with_index { |entry, index| layout_entry(entry, page:, index:, word: false) }
    return if result.any?(&:nil?)
    return unless result.each_cons(2).all? { |left, right| left[:span_end] < right[:span_start] }

    result
  end

  def validate_words(page)
    entries = page["words"]
    return false unless entries.is_a?(Array) && entries.size.between?(1, MAX_WORDS)

    words = entries.map.with_index { |entry, index| layout_entry(entry, page:, index:, word: true) }
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

  def layout_entry(entry, page:, index:, word:)
    return unless entry.is_a?(Hash)

    text = bounded_text(entry["content"], word ? MAX_WORD_CONTENT_BYTES : MAX_LINE_CONTENT_BYTES)
    return if text.blank? || text.match?(/[\r\n\u0085\u2028\u2029]/)

    raw_span = word ? entry["span"] : entry["spans"]&.then { |spans| spans.sole if spans.is_a?(Array) && spans.one? }
    span = valid_span(raw_span)
    return if span.nil? || mapper.length(text) != span[:length]
    return unless mapper.slice(content, offset: span[:offset], length: span[:length]) == text

    bounds = polygon_bounds(entry["polygon"], page:)
    return if bounds.nil?

    {
      content: text,
      span_start: span[:offset],
      span_end: span[:offset] + span[:length],
      bounds:,
      index:,
      words: []
    }
  end

  def descriptor_at(line, index:, owned:)
    name = product_name(line)
    return if name.nil? || non_item_overlap?(line)
    return if index.positive? && !owned[index - 1] && product_name(lines[index - 1])

    components = components_at(index)
    return if components.nil?
    return if name[:tax_inclusion] && components[:reference] &&
      name[:tax_inclusion] != components[:reference][:tax_inclusion]

    entries = lines[index..components[:last_index]]
    return unless entries.each_cons(2).all? { |upper, lower| neighbors?(upper, lower) }
    return unless entries.all? { |entry| word_coverage?(entry) }

    options = options_for(components)
    return if options.nil?

    identity = "azure_calculation_layout_p0_name_l#{index}_s#{line[:span_start]}_e#{line[:span_end]}_block_e#{entries.last[:span_end]}"
    quantity = components[:quantity]
    @fragment_components[identity] = {
      "Description" => name[:evidence],
      "Price" => components.dig(:price, :evidence) || components.dig(:reference, :evidence, :reference_price),
      "Quantity" => quantity && quantity[:evidence],
      "QuantityUnit" => quantity && quantity[:unit_evidence],
      "TotalPrice" => components.dig(:total, :evidence)
    }
    {
      source_provider: SOURCE_KIND,
      validation_contract_version: VALIDATION_CONTRACT_VERSION,
      item_identity: identity,
      source_field_path: "pages[0].lines[#{index}]",
      block_provider_span_start: line[:span_start],
      block_provider_span_end: entries.last[:span_end],
      owned_line_indexes: entries.map { |entry| entry[:index] },
      structured_item_indexes: [],
      destination_evidence: evidence(line),
      item_tax_evidence: name[:tax_evidence],
      options:,
      printed_line_total: components.dig(:total, :value),
      layout_item: {
        name: name[:text],
        price: components.dig(:price, :value)&.to_i || components.dig(:reference, :value),
        quantity: quantity && quantity[:value],
        quantity_unit_code: quantity && quantity[:unit],
        line_total: components.dig(:total, :value)&.to_i,
        tax_rate: name[:tax_rate],
        ocr_item_identity: identity
      }
    }
  end

  def components_at(index)
    next_line = lines[index + 1]
    return if next_line.nil?

    price = captured_component(next_line, profile.ocr_item_calculation_layout_price_line_pattern, :amount)
    reference = reference_component(next_line)
    if price || reference
      quantity = quantity_component(lines[index + 2], count: !price.nil?)
      total = total_component(lines[index + 3])
      return if quantity.nil? || total.nil?

      return { price:, reference:, quantity:, total:, last_index: index + 3 }
    end

    total = total_component(next_line)
    return { total:, last_index: index + 1 } if total

    quantity = quantity_component(next_line, count: true)
    return if quantity.nil?

    total = total_component(lines[index + 2])
    { quantity:, total:, last_index: total ? index + 2 : index + 1 }
  end

  def options_for(components)
    options = []
    if components[:price]
      price = components[:price]
      quantity = components[:quantity]
      ReceiptAmountService.count_item_extension_projection(
        price_amount: price[:value],
        purchased_quantity: quantity[:value],
        purchased_unit_code: quantity[:unit]
      )
      options << {
        pricing_source_kind: "count_unit_price",
        source: { price_amount: price[:value], quantity: quantity[:value], quantity_unit_code: quantity[:unit] },
        evidence: { price: price[:evidence], quantity: quantity[:evidence], quantity_unit: quantity[:unit_evidence] }
      }
    elsif components[:reference]
      reference = components[:reference]
      quantity = components[:quantity]
      ReceiptAmountService.reference_item_extension_projection(
        reference_price_amount: reference[:value],
        reference_quantity: reference[:quantity],
        reference_unit_code: reference[:unit],
        purchased_quantity: quantity[:value],
        purchased_unit_code: quantity[:unit]
      )
      options << {
        pricing_source_kind: "reference_quantity_price",
        source: {
          reference_price_amount: reference[:value],
          reference_quantity: reference[:quantity],
          reference_quantity_unit_code: reference[:unit],
          purchased_quantity: quantity[:value],
          purchased_quantity_unit_code: quantity[:unit],
          reference_price_tax_inclusion: reference[:tax_inclusion]
        },
        evidence: reference[:evidence].merge(quantity: quantity[:evidence], quantity_unit: quantity[:unit_evidence])
      }
    end
    if (total = components[:total])
      options << {
        pricing_source_kind: "explicit_line_total",
        source: { line_total_amount: total[:value] },
        evidence: { line_total: total[:evidence] }
      }
    end
    options
  rescue ReceiptAmountService::InvalidItemSourceError
    nil
  end

  def captured_component(line, pattern, capture)
    return if line.nil?

    match = pattern.match(line[:content])
    return if match.nil?

    value = decimal(match[capture])
    return if value.nil?

    { value:, evidence: evidence(line, match:, capture:) }
  end

  def quantity_component(line, count:)
    return if line.nil?

    pattern = count ? profile.ocr_item_calculation_count_quantity_line_pattern : profile.ocr_reference_pricing_item_layout_purchased_quantity_line_pattern
    match = pattern.match(line[:content])
    return if match.nil? || (count && match[:label].nil?)

    value = decimal(match[:quantity])
    unit = profile.resolve_quantity_unit(match[:unit])
    return if value.nil? || !unit.known?
    return if count && !ReceiptQuantityUnit.countable?(unit.code)
    return unless BigDecimal(value).positive? && BigDecimal(value) <= 9_999
    return if count && !BigDecimal(value).frac.zero?

    {
      value:,
      unit: unit.code,
      evidence: evidence(line, match:, capture: :quantity),
      unit_evidence: evidence(line, match:, capture: :unit)
    }
  end

  def reference_component(line)
    return if line.nil?

    match = profile.ocr_item_calculation_layout_reference_line_pattern.match(line[:content])
    return if match.nil?

    value = decimal(match[:amount])
    quantity = decimal(match[:quantity])
    unit = profile.resolve_quantity_unit(match[:unit])
    tax_inclusion = profile.reference_price_tax_inclusion(match[:tax])
    return if value.nil? || quantity.nil? || !unit.known? || !%w[gross net].include?(tax_inclusion)

    {
      value:,
      quantity:,
      unit: unit.code,
      tax_inclusion:,
      evidence: {
        reference_price: evidence(line, match:, capture: :amount),
        reference_quantity: evidence(line, match:, capture: :quantity),
        reference_unit: evidence(line, match:, capture: :unit),
        tax_inclusion: evidence(line, match:, capture: :tax)
      }
    }
  end

  def total_component(line)
    component = captured_component(line, profile.ocr_reference_pricing_item_layout_printed_total_line_pattern, :amount)
    return if component.nil? || !BigDecimal(component[:value]).frac.zero? || BigDecimal(component[:value]) > 999_999_999_999

    component
  end

  def product_name(line)
    text = line[:content]
    match = profile.ocr_item_calculation_layout_name_tax_pattern.match(text)
    name = match ? match[:name] : text
    return if name.bytesize > MAX_NAME_BYTES || !name.scan(/\X/).size.between?(2, 32)
    return unless name.match?(/[\p{L}\p{N}]/u)
    return if name.match?(/[\/／]/)
    return if profile.ocr_reference_pricing_line_group_destination_identifier_conflict_patterns.any? { |pattern| name.match?(pattern) }
    return if name.match?(profile.ocr_item_calculation_package_quantity_pattern)
    return if name.match?(profile.ocr_item_calculation_package_capacity_pattern)
    return if name.match?(profile.ocr_item_calculation_count_uncertain_pattern)
    return if name.match?(profile.ocr_item_calculation_layout_price_line_pattern)
    return if name.match?(profile.ocr_item_calculation_count_quantity_line_pattern)
    return if name.match?(profile.ocr_reference_pricing_item_layout_purchased_quantity_line_pattern)
    return if name.match?(profile.ocr_reference_pricing_item_layout_printed_total_line_pattern)
    return if name.match?(profile.ocr_tax_anchor_pattern)

    tax_rate = match && decimal(match[:rate])
    return if match && (tax_rate.nil? || BigDecimal(tax_rate) > 100)

    {
      text: name,
      evidence: match ? evidence(line, match:, capture: :name) : evidence(line),
      tax_rate: tax_rate && BigDecimal(tax_rate) / 100,
      tax_inclusion: match && profile.reference_price_tax_inclusion(match[:tax]),
      tax_evidence: match && evidence(line, match:, capture: :rate)
    }
  end

  def evidence(line, match: nil, capture: nil)
    start = line[:span_start]
    finish = line[:span_end]
    if match
      start += mapper.length(line[:content][0...match.begin(capture)])
      finish = start + mapper.length(match[capture])
    end
    {
      source_field_path: "pages[0].lines[#{line[:index]}]",
      page_index: 0,
      line_index: line[:index],
      provider_span_start: start,
      provider_span_end: finish,
      word_spans: line[:words].filter_map do |word|
        next unless word[:span_start] < finish && start < word[:span_end]

        {
          word_index: word[:index],
          provider_span_start: word[:span_start],
          provider_span_end: word[:span_end]
        }
      end
    }
  end

  def associate_structured_fragments(descriptors)
    structured_items.each_with_index.all? do |item, index|
      children = item["valueObject"]
      next false unless item.size <= MAX_FIELD_ENTRIES && children.is_a?(Hash)
      next false unless children.size.between?(1, STRUCTURED_FIELD_NAMES.size)
      next false unless (children.keys - STRUCTURED_FIELD_NAMES).empty?
      next false if item.key?("content") && bounded_text(item["content"], MAX_FIELD_BYTES).nil?

      spans = field_spans(item, maximum: MAX_PARENT_SPANS)
      next false if spans.nil?
      next false unless children.values.all? { |field| exact_child_field?(field, parent_spans: spans) }

      owner = descriptors.bsearch { |descriptor| descriptor[:block_provider_span_end] > spans.first[:offset] }
      next false if owner.nil? || !owner[:structured_item_indexes].empty?
      next false unless spans.first[:offset] >= owner[:block_provider_span_start]
      next false unless spans.last[:offset] + spans.last[:length] <= owner[:block_provider_span_end]
      next false unless structured_fragment_matches?(children, owner)

      owner[:structured_item_indexes] << index
      true
    end
  end

  def field_spans(field, maximum:)
    values = field["spans"]
    return unless values.is_a?(Array) && values.size.between?(1, maximum)

    spans = values.map { |span| valid_span(span) }
    return if spans.any?(&:nil?)
    return unless spans.each_cons(2).all? { |left, right| left[:offset] + left[:length] <= right[:offset] }

    spans
  end

  def exact_child_field?(field, parent_spans:)
    return false unless field.is_a?(Hash) && field.size <= MAX_FIELD_ENTRIES

    spans = field_spans(field, maximum: 1)
    text = bounded_text(field["content"], MAX_LINE_CONTENT_BYTES)
    return false if spans.nil? || text.nil?

    span = spans.sole
    return false unless parent_spans.any? do |parent|
      span[:offset] >= parent[:offset] && span[:offset] + span[:length] <= parent[:offset] + parent[:length]
    end

    mapper.slice(content, offset: span[:offset], length: span[:length]) == text
  end

  def structured_fragment_matches?(children, descriptor)
    children.all? do |field_name, field|
      component = @fragment_components.fetch(descriptor[:item_identity])[field_name]
      next false if component.nil?
      next description_fragment_matches?(field, component) if field_name == "Description"
      next false unless field_owns_component?(field, component)

      case field_name
      when "Price", "Quantity", "TotalPrice"
        expected = case field_name
        when "Price"
          descriptor.dig(:layout_item, :price)
        when "Quantity"
          descriptor.dig(:layout_item, :quantity)
        when "TotalPrice"
          descriptor.dig(:layout_item, :line_total)
        end
        value = structured_numeric_value(field, field_name:)
        expected && value.is_a?(Numeric) && value.finite? && value.between?(0, 999_999_999_999) &&
          BigDecimal(value.to_s) == BigDecimal(expected.to_s)
      when "QuantityUnit"
        value = bounded_text(field["valueString"], MAX_WORD_CONTENT_BYTES)
        next false if value.nil?

        unit = profile.resolve_quantity_unit(value)
        unit.known? && unit.code == descriptor.dig(:layout_item, :quantity_unit_code)
      else
        false
      end
    end
  end

  def description_fragment_matches?(field, component)
    span = field_spans(field, maximum: 1).sole
    start = span[:offset]
    finish = start + span[:length]
    return false unless start >= component[:provider_span_start] && finish <= component[:provider_span_end]

    words = lines[component[:line_index]][:words]
    words.any? { |word| word[:span_start] == start } &&
      words.any? { |word| word[:span_end] == finish }
  end

  def field_owns_component?(field, component)
    span = field_spans(field, maximum: 1).sole
    line = lines[component[:line_index]]
    span[:offset] >= line[:span_start] && span[:offset] + span[:length] <= line[:span_end] &&
      span[:offset] <= component[:provider_span_start] &&
      span[:offset] + span[:length] >= component[:provider_span_end]
  end

  def structured_numeric_value(field, field_name:)
    return field["valueNumber"] if field_name == "Quantity"

    value = field["valueCurrency"]
    return unless value.is_a?(Hash) && value.size <= 3 && value["currencyCode"] == "JPY"

    value["amount"]
  end

  def prepare_non_item_spans
    spans = []
    fields.each do |key, field|
      next if key == "Items"
      return false unless field.is_a?(Hash) && field.size <= MAX_FIELD_ENTRIES
      return false if field.key?("content") && bounded_text(field["content"], MAX_FIELD_BYTES).nil?
      next unless field.key?("spans")

      validated = field_spans(field, maximum: MAX_LINES)
      return false if validated.nil?

      spans.concat(validated)
    end
    @non_item_spans = []
    spans.sort_by { |span| span[:offset] }.each do |span|
      range = { span_start: span[:offset], span_end: span[:offset] + span[:length] }
      previous = @non_item_spans.last
      if previous && range[:span_start] <= previous[:span_end]
        previous[:span_end] = [ previous[:span_end], range[:span_end] ].max
      else
        @non_item_spans << range
      end
    end
    true
  end

  def non_item_overlap?(line)
    span = @non_item_spans.bsearch { |entry| entry[:span_end] > line[:span_start] }
    span && span[:span_start] < line[:span_end]
  end

  def complete_item_region?(owned)
    headers = lines.select do |line|
      text = line[:content].strip
      match = profile.ocr_store_name_header_pattern.match(text)
      match && match[0] == text
    end
    return false if headers.size > 1

    start_index = headers.empty? ? 0 : headers.sole[:index] + 1
    boundary = lines.find do |line|
      line[:index] >= start_index && receipt_summary_line?(line[:content])
    end
    return false if boundary.nil? || boundary[:index] <= start_index
    return false unless lines.drop(boundary[:index]).all? { |line| receipt_footer_line?(line[:content]) }

    owned.each_with_index.all? do |value, index|
      expected = index >= start_index && index < boundary[:index]
      value == expected
    end
  end

  def receipt_summary_line?(text)
    text.match?(profile.ocr_strict_receipt_subtotal_line_pattern) ||
      text.match?(profile.ocr_strict_receipt_summary_total_line_pattern)
  end

  def receipt_footer_line?(text)
    return true if receipt_summary_line?(text)
    return true if text.match?(profile.analysis_tax_summary_line_pattern)
    return true if text.match?(profile.ocr_tax_anchor_pattern) &&
      text.match?(profile.analysis_tax_summary_continuation_line_pattern)

    patterns = [
      profile.analysis_fallback_payment_line_pattern,
      profile.analysis_cash_deposit_label_pattern,
      profile.analysis_cash_change_label_pattern,
      profile.analysis_fallback_payment_amount_label_pattern
    ]
    patterns.any? do |pattern|
      match = pattern.match(text)
      next false unless match && match.begin(0).zero?

      amount = text[match.end(0)..].sub(/\A[ \t:：]*/, "")
      amount.match?(profile.ocr_strict_receipt_summary_total_amount_line_pattern)
    end
  end

  def neighbors?(upper, lower)
    return false unless lower[:span_start] == upper[:span_end] + 1
    return false unless mapper.slice(content, offset: upper[:span_end], length: 1) == "\n"

    first = upper[:bounds]
    second = lower[:bounds]
    gap = second[:top] - first[:bottom]
    height = [ first[:bottom] - first[:top], second[:bottom] - second[:top] ].max
    gap >= 0 && gap / height <= MAX_VERTICAL_GAP_RATIO &&
      [ first[:right], second[:right] ].min > [ first[:left], second[:left] ].max
  end

  def word_coverage?(line)
    words = line[:words]
    return false if words.empty?
    return false unless words.first[:span_start] == line[:span_start] && words.last[:span_end] == line[:span_end]

    words.each_cons(2).all? do |left, right|
      gap = right[:span_start] - left[:span_end]
      gap.zero? || mapper.slice(content, offset: left[:span_end], length: gap)&.match?(/\A[ \t]+\z/)
    end
  end

  def decimal(value)
    return unless value.is_a?(String) && value.bytesize <= 32

    normalized = value.unicode_normalize(:nfkc).delete(",")
    return unless normalized.match?(DECIMAL_PATTERN)

    BigDecimal(normalized).to_s("F").sub(/\.0\z/, "")
  end

  def bounded_text(value, limit)
    return unless value.is_a?(String)
    return unless value.valid_encoding?
    return if value.bytesize > limit
    return if value.match?(CONTROL_CHARACTER_PATTERN)

    value
  end

  def valid_span(value)
    return unless value.is_a?(Hash)

    offset = value["offset"]
    length = value["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length.positive?
    return if offset > MAX_PROVIDER_SPAN_VALUE || length > MAX_PROVIDER_SPAN_VALUE - offset

    { offset:, length: }
  end

  def polygon_bounds(polygon, page:)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |value| value.is_a?(Numeric) && value.finite? }
    xs = polygon.each_slice(2).map(&:first)
    ys = polygon.each_slice(2).map(&:last)
    return unless xs.all? { |value| value.between?(0, page["width"]) } && ys.all? { |value| value.between?(0, page["height"]) }
    return unless convex_polygon?(polygon)

    left, right = xs.minmax.map { |value| Rational(value.to_s) }
    top, bottom = ys.minmax.map { |value| Rational(value.to_s) }
    return unless right > left && bottom > top

    { left:, right:, top:, bottom: }
  end

  def convex_polygon?(polygon)
    points = polygon.each_slice(2).map { |pair| pair.map { |value| Rational(value.to_s) } }
    crosses = 4.times.map do |index|
      first = points[index]
      second = points[(index + 1) % 4]
      third = points[(index + 2) % 4]
      (second[0] - first[0]) * (third[1] - second[1]) -
        (second[1] - first[1]) * (third[0] - second[0])
    end
    crosses.all?(&:positive?) || crosses.all?(&:negative?)
  end

  def polygon_within?(inner, outer)
    inner[:left] >= outer[:left] - 1 && inner[:right] <= outer[:right] + 1 &&
      inner[:top] >= outer[:top] - 1 && inner[:bottom] <= outer[:bottom] + 1
  end

  def within?(inner, outer)
    inner[:span_start] >= outer[:span_start] && inner[:span_end] <= outer[:span_end]
  end
end
