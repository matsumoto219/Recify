require "set"

class Ocr::ResponseParser::ItemCalculationModeCandidateExtractor
  MAX_ITEMS = 100
  MAX_LINES = 150
  MAX_CONTENT_BYTES = Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  MAX_ITEM_CONTENT_BYTES = 4_096
  MAX_FIELD_CONTENT_BYTES = 512
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  MAX_AMOUNT = BigDecimal("999999999999")
  MAX_QUANTITY = BigDecimal("9999")
  MAX_EXACT_NUMBER_BYTES = 64
  MAX_CURRENCY_CODE_BYTES = 8

  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  SOURCE_PROVIDER = "azure_structured"
  PRICING_SOURCE_KINDS = %w[count_unit_price explicit_line_total].freeze
  CONFLICTS = %w[count_semantics discount package reference_expression].freeze
  JPY_CURRENCY_SYMBOLS = %w[¥ 円].freeze
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /\r\n|[\n\r\u0085\u2028\u2029]/.freeze
  LINE_BREAK_CAPTURE_PATTERN = /(\r\n|[\n\r\u0085\u2028\u2029])/.freeze
  PROMOTIONAL_DISCOUNT_LABEL_VALUE_PATTERN = /[0-9¥￥円%％@＠\/／+\-−▲△]/.freeze
  MONEY_CONTENT_PATTERN = /\A\s*(?:(?<prefix>¥|JPY)\s*)?(?<amount>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(?:\s*(?<suffix>円))?\s*\z/i.freeze
  UNIT_PRICE_CONTENT_PATTERN = /\A\s*(?:[x×]\s*)?@\s*(?:(?<prefix>¥|JPY)\s*)?(?<amount>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(?:\s*(?<suffix>円))?\)?\s*\z/i.freeze
  QUANTITY_CONTENT_PATTERN = /\A\s*(?<amount>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)\s*\z/.freeze
  UNIT_TOKEN_PATTERN = /\p{L}+/u.freeze

  def self.call(
    analyze_result:,
    profile:,
    reference_pricing_candidates: [],
    discount_item_indexes: [],
    destination_item_indexes: nil,
    item_layout_descriptors: [],
    reference_conflict_item_indexes: []
  )
    new(
      analyze_result: analyze_result,
      profile: profile,
      reference_pricing_candidates: reference_pricing_candidates,
      discount_item_indexes: discount_item_indexes,
      destination_item_indexes: destination_item_indexes,
      item_layout_descriptors: item_layout_descriptors,
      reference_conflict_item_indexes: reference_conflict_item_indexes
    ).call
  end

  def initialize(
    analyze_result:,
    profile:,
    reference_pricing_candidates:,
    discount_item_indexes:,
    destination_item_indexes: nil,
    item_layout_descriptors: [],
    reference_conflict_item_indexes: []
  )
    @analyze_result = analyze_result
    @profile = profile
    @reference_pricing_candidates = Array(reference_pricing_candidates).filter_map do |candidate|
      normalized_hash(candidate)
    end
    reference_pricing_item_indexes = @reference_pricing_candidates.filter_map do |normalized|
      item_index = normalized[:item_index]
      item_index if item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
    end
    reference_conflict_item_indexes = Array(reference_conflict_item_indexes).select do |item_index|
      item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
    end
    @reference_pricing_item_indexes = (reference_pricing_item_indexes + reference_conflict_item_indexes).to_set
    @valid_reference_pricing_item_indexes = @reference_pricing_candidates.filter_map do |normalized|
      item_index = normalized[:item_index]
      next unless normalized[:validation_state] == "valid"
      next unless Array(normalized[:rejection_reasons]).empty?

      item_index if item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
    end.to_set
    @discount_item_indexes = Array(discount_item_indexes).select do |item_index|
      item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
    end.to_set
    @destination_item_indexes = if destination_item_indexes.nil?
      nil
    else
      Array(destination_item_indexes).select do |item_index|
        item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
      end.to_set
    end
    item_layout_descriptors = Array(item_layout_descriptors)
    @item_layout_descriptors = item_layout_descriptors.select do |descriptor|
      descriptor.is_a?(Hash) && descriptor[:source_kind] == "azure_item_layout"
    end
    @item_layout_descriptors = [] if item_layout_descriptors.size > MAX_ITEMS ||
      @item_layout_descriptors.size != item_layout_descriptors.size
  end

  def call
    return [] unless provider_context_valid?
    return [] unless items.is_a?(Array) && items.size <= MAX_ITEMS

    parent_spans = items.map { |item| item.is_a?(Hash) ? single_span(item) : nil }
    overlapping_indexes = overlapping_parent_indexes(parent_spans)
    layout_candidates = item_layout_descriptors.filter_map { |descriptor| extract_layout_candidate(descriptor) }
    layout_replacement_indexes = layout_candidates.filter_map { |candidate| candidate[:item_index] }.to_set
    structured_candidates = items.filter_map.with_index do |item, item_index|
      next unless destination_item_indexes.nil? || destination_item_indexes.include?(item_index)
      next if layout_replacement_indexes.include?(item_index)
      next if overlapping_indexes.include?(item_index)

      extract_candidate(item, item_index, parent_spans.fetch(item_index))
    rescue EncodingError, ArgumentError, TypeError
      nil
    end

    (structured_candidates + layout_candidates).sort_by { |candidate| candidate.fetch(:item_index) }
  end

  private

  attr_reader :analyze_result, :content, :destination_item_indexes, :discount_item_indexes,
    :item_layout_descriptors, :items, :mapper, :profile, :reference_pricing_item_indexes,
    :reference_pricing_candidates, :valid_reference_pricing_item_indexes

  def provider_context_valid?
    return false unless analyze_result.is_a?(Hash)
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return false unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    return false if mapper.nil?

    @content = safe_content(analyze_result["content"], maximum_bytes: MAX_CONTENT_BYTES)
    return false if content.nil?

    documents = analyze_result["documents"]
    return false unless documents.is_a?(Array) && documents.one? && documents.sole.is_a?(Hash)

    fields = documents.sole["fields"]
    items_field = fields.is_a?(Hash) ? fields["Items"] : nil
    @items = if items_field.is_a?(Hash)
      items_field["valueArray"]
    elsif items_field.nil? && item_layout_descriptors.any?
      []
    end
    items.is_a?(Array)
  end

  def extract_candidate(item, item_index, parent_span)
    return unless item.is_a?(Hash) && parent_span
    return unless exact_provider_content?(item["content"], parent_span, maximum_bytes: MAX_ITEM_CONTENT_BYTES)

    value_object = item["valueObject"]
    return unless value_object.is_a?(Hash)

    description = description_component(
      value_object["Description"],
      parent_span: parent_span,
      field_path: item_field_path(item_index, "Description")
    )
    return if description.nil?

    printed_line_total = money_component(
      value_object["TotalPrice"],
      parent_span: parent_span,
      field_path: item_field_path(item_index, "TotalPrice")
    )
    count_option = count_option(value_object, item, item_index, parent_span, description: description)
    explicit_option = explicit_option(printed_line_total, item_index, description: description)
    if count_option && explicit_option && option_evidence_overlaps?(count_option, explicit_option)
      count_option = nil
    end
    options = [ count_option, explicit_option ].compact
    return if options.empty? && !valid_reference_pricing_item_indexes.include?(item_index)

    {
      candidate_id: "azure_items_#{item_index}_item_calculation_mode",
      item_identity: item_identity(item_index, parent_span),
      item_index: item_index,
      source_provider: SOURCE_PROVIDER,
      provider_model_id: SUPPORTED_MODEL_ID,
      provider_api_version: SUPPORTED_API_VERSION,
      string_index_type: mapper.index_type,
      source_field_path: item_field_path(item_index),
      provider_span_start: parent_span.begin,
      provider_span_end: parent_span.end,
      destination_evidence: description.fetch(:evidence),
      printed_line_total: printed_line_total,
      conflicts: conflicts_for(item, item_index),
      options: options
    }
  end

  def extract_layout_candidate(descriptor)
    layout_item = descriptor[:layout_item]
    destination_kind = descriptor[:destination_kind]
    structured_destination = destination_kind == "azure_structured_item"
    return unless layout_item.is_a?(Hash) || structured_destination

    item_index = descriptor[:structured_item_index]
    item_index = 0 if item_index.nil? && items.empty?
    return unless item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
    return unless !structured_destination || valid_structured_layout_reference_candidate?(descriptor, item_index:)

    printed_line_total = normalized_hash(descriptor[:printed_line_total])
    amount = lexeme_decimal(printed_line_total[:amount])
    evidence = normalized_hash(printed_line_total[:evidence])
    return unless amount && amount.frac.zero? && amount.between?(BigDecimal("0"), MAX_AMOUNT)
    return unless valid_layout_evidence?(evidence)

    candidate_id = descriptor[:candidate_id]
    item_identity = descriptor[:item_identity]
    block_start = descriptor[:block_provider_span_start]
    block_end = descriptor[:block_provider_span_end]
    name_line_index = descriptor[:name_line_index]
    return unless candidate_id.is_a?(String) && candidate_id.bytesize.between?(1, 256)
    return unless item_identity.is_a?(String) && item_identity.bytesize.between?(1, 256)
    return unless valid_provider_range?(block_start, block_end)
    return unless name_line_index.is_a?(Integer) && name_line_index.between?(0, MAX_LINES - 1)

    {
      candidate_id: "#{candidate_id}_item_calculation_mode",
      item_identity: item_identity,
      item_index: item_index,
      source_provider: "azure_item_layout",
      provider_model_id: SUPPORTED_MODEL_ID,
      provider_api_version: SUPPORTED_API_VERSION,
      string_index_type: mapper.index_type,
      source_field_path: "pages[0].lines[#{name_line_index}]",
      provider_span_start: block_start,
      provider_span_end: block_end,
      destination_evidence: descriptor[:destination_evidence],
      destination_kind: destination_kind,
      owned_line_indexes: descriptor[:owned_line_indexes],
      printed_line_total: printed_line_total,
      conflicts: [],
      options: [
        {
          proposal_id: "#{candidate_id}_explicit_line_total",
          pricing_source_kind: "explicit_line_total",
          source: { line_total_amount: canonical_decimal_string(amount) },
          evidence: { line_total: evidence }
        }
      ]
    }
  rescue ArgumentError, TypeError
    nil
  end

  def valid_structured_layout_reference_candidate?(descriptor, item_index:)
    candidate_id = descriptor.dig(:reference_pricing_candidate, :candidate_id)
    item_identity = descriptor[:item_identity]
    matches = reference_pricing_candidates.select do |candidate|
      candidate[:source_kind] == "azure_item_layout" &&
        candidate[:candidate_id] == candidate_id &&
        candidate[:item_identity] == item_identity &&
        candidate[:item_index] == item_index &&
        candidate[:destination_kind] == "azure_structured_item" &&
        candidate[:structured_item_index] == item_index &&
        candidate[:validation_state] == "valid" &&
        Array(candidate[:rejection_reasons]).empty? &&
        candidate.dig(:tax_inclusion_evidence, :kind) == "single_item_receipt_gross_summary"
    end

    matches.one?
  end

  def valid_layout_evidence?(evidence)
    return false unless evidence[:source_provider] == "azure_item_layout"
    return false unless evidence[:string_index_type] == mapper.index_type

    valid_provider_range?(evidence[:provider_span_start], evidence[:provider_span_end])
  end

  def valid_provider_range?(range_start, range_end)
    range_start.is_a?(Integer) && range_end.is_a?(Integer) &&
      range_start.between?(0, MAX_PROVIDER_SPAN_VALUE) &&
      range_end > range_start && range_end <= MAX_PROVIDER_SPAN_VALUE
  end

  def count_option(value_object, item, item_index, parent_span, description:)
    return if unsafe_count_context?(item, item_index)

    price = money_component(
      value_object["Price"],
      parent_span: parent_span,
      field_path: item_field_path(item_index, "Price"),
      allow_unit_price_marker: true
    )
    quantity = quantity_component(
      value_object["Quantity"],
      parent_span: parent_span,
      field_path: item_field_path(item_index, "Quantity")
    )
    quantity_unit = quantity_unit_component(
      value_object["QuantityUnit"],
      parent_span: parent_span,
      field_path: item_field_path(item_index, "QuantityUnit")
    )
    return if [ price, quantity, quantity_unit ].any?(&:nil?)
    return unless nonoverlapping_evidence?(
      description.fetch(:evidence),
      price.fetch(:evidence),
      quantity.fetch(:evidence),
      quantity_unit.fetch(:evidence)
    )

    {
      proposal_id: "azure_items_#{item_index}_count_unit_price",
      pricing_source_kind: "count_unit_price",
      source: {
        price_amount: price.fetch(:amount),
        quantity: quantity.fetch(:amount),
        quantity_unit_code: quantity_unit.fetch(:unit_code)
      },
      evidence: {
        price: price.fetch(:evidence),
        quantity: quantity.fetch(:evidence),
        quantity_unit: quantity_unit.fetch(:evidence)
      }
    }
  end

  def explicit_option(printed_line_total, item_index, description:)
    return if printed_line_total.nil?
    return unless nonoverlapping_evidence?(
      description.fetch(:evidence),
      printed_line_total.fetch(:evidence)
    )

    {
      proposal_id: "azure_items_#{item_index}_explicit_line_total",
      pricing_source_kind: "explicit_line_total",
      source: {
        line_total_amount: printed_line_total.fetch(:amount)
      },
      evidence: {
        line_total: printed_line_total.fetch(:evidence)
      }
    }
  end

  def money_component(field, parent_span:, field_path:, allow_unit_price_marker: false)
    return unless field.is_a?(Hash)

    value_currency = field["valueCurrency"]
    return unless value_currency.is_a?(Hash)
    currency_code = safe_content(
      value_currency["currencyCode"],
      maximum_bytes: MAX_CURRENCY_CODE_BYTES
    )
    return unless currency_code == "JPY"

    structured = provider_decimal(value_currency["amount"])
    printed = exact_money_from_content(
      field["content"],
      declared_symbol: value_currency["currencySymbol"],
      allow_unit_price_marker: allow_unit_price_marker
    )
    span = single_span(field)
    return unless structured && printed && structured == printed
    return unless structured.frac.zero?
    return unless structured.between?(BigDecimal("0"), MAX_AMOUNT)
    return unless span_within?(span, parent_span)
    return unless exact_provider_content?(field["content"], span, maximum_bytes: MAX_FIELD_CONTENT_BYTES)

    {
      amount: canonical_decimal_string(structured),
      evidence: component_evidence(field_path, span)
    }
  end

  def quantity_component(field, parent_span:, field_path:)
    return unless field.is_a?(Hash)

    structured = provider_decimal(field["valueNumber"])
    printed = exact_quantity_from_content(field["content"])
    span = single_span(field)
    return unless structured && printed && structured == printed
    return unless structured.frac.zero? && structured.between?(BigDecimal("1"), MAX_QUANTITY)
    return unless span_within?(span, parent_span)
    return unless exact_provider_content?(field["content"], span, maximum_bytes: MAX_FIELD_CONTENT_BYTES)

    {
      amount: canonical_decimal_string(structured),
      evidence: component_evidence(field_path, span)
    }
  end

  def quantity_unit_component(field, parent_span:, field_path:)
    return unless field.is_a?(Hash)
    value_string = safe_content(field["valueString"], maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    field_content = safe_content(field["content"], maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    return if value_string.nil? || field_content.nil?

    structured_resolution = profile.resolve_quantity_unit(value_string)
    return unless structured_resolution.known?
    return unless ReceiptQuantityUnit.countable?(structured_resolution.code)

    content_resolutions = field_content.unicode_normalize(:nfkc).scan(UNIT_TOKEN_PATTERN).filter_map do |token|
      resolution = profile.resolve_quantity_unit(token)
      resolution.code if resolution.known?
    end.uniq
    return unless content_resolutions == [ structured_resolution.code ]

    span = single_span(field)
    return unless span_within?(span, parent_span)
    return unless exact_provider_content?(field_content, span, maximum_bytes: MAX_FIELD_CONTENT_BYTES)

    {
      unit_code: structured_resolution.code,
      evidence: component_evidence(field_path, span)
    }
  end

  def exact_money_from_content(value, declared_symbol:, allow_unit_price_marker:)
    value = safe_content(value, maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    return if value.nil?

    normalized = value.unicode_normalize(:nfkc)
    normalized = normalized.sub(profile.ocr_item_calculation_tax_marker_prefix_pattern, "")
    match = MONEY_CONTENT_PATTERN.match(normalized)
    match ||= UNIT_PRICE_CONTENT_PATTERN.match(normalized) if allow_unit_price_marker
    return if match.nil?

    if declared_symbol
      declared_symbol = safe_content(declared_symbol, maximum_bytes: MAX_CURRENCY_CODE_BYTES)
      return if declared_symbol.nil?

      declared_symbol = declared_symbol.unicode_normalize(:nfkc)
      return unless JPY_CURRENCY_SYMBOLS.include?(declared_symbol)
      return if declared_symbol == "¥" && match[:prefix] != "¥"
      return if declared_symbol == "円" && match[:suffix] != "円"
    end

    lexeme_decimal(match[:amount].delete(","))
  end

  def exact_quantity_from_content(value)
    value = safe_content(value, maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    return if value.nil?

    match = QUANTITY_CONTENT_PATTERN.match(value.unicode_normalize(:nfkc))
    return if match.nil?

    lexeme_decimal(match[:amount].delete(","))
  end

  def provider_decimal(value)
    source = case value
    when Integer
      value.to_s
    when Float
      return unless value.finite?

      value.to_s
    else
      return
    end
    return if source.bytesize > MAX_EXACT_NUMBER_BYTES
    return unless source.match?(/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/)

    BigDecimal(source)
  rescue ArgumentError
    nil
  end

  def lexeme_decimal(value)
    return unless value.is_a?(String) && value.bytesize <= MAX_EXACT_NUMBER_BYTES
    return unless value.match?(/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/)

    BigDecimal(value)
  rescue ArgumentError
    nil
  end

  def canonical_decimal_string(value)
    value.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, '\\1')
  end

  def conflicts_for(item, item_index)
    content = safe_content(item["content"], maximum_bytes: MAX_ITEM_CONTENT_BYTES)
    return CONFLICTS if content.nil?

    content = content.unicode_normalize(:nfkc)
    conflicts = []
    conflicts << "count_semantics" if content.match?(profile.ocr_item_calculation_count_uncertain_pattern)
    conflicts << "discount" if discount_conflict?(item, item_index, content)
    package_conflict = content.match?(profile.ocr_item_calculation_package_quantity_pattern) ||
      content.match?(profile.ocr_item_calculation_package_capacity_pattern)
    conflicts << "package" if package_conflict
    conflicts << "reference_expression" if reference_pricing_item_indexes.include?(item_index)
    conflicts & CONFLICTS
  end

  def unsafe_count_context?(item, item_index)
    conflicts_for(item, item_index).any?
  end

  def discount_conflict?(item, item_index, content)
    return true if discount_item_indexes.include?(item_index)
    return false unless content.match?(profile.ocr_item_discount_keyword_pattern)

    !exact_informational_per_unit_discount_block?(item, item_index, content)
  end

  def exact_informational_per_unit_discount_block?(item, item_index, content)
    return false unless items.one?

    reference_candidate = exact_promotional_reference_candidate(item, item_index)
    return false if reference_candidate.nil?

    parent_span = single_span(item)
    lines = provider_content_lines(content, parent_span)
    return false if lines.nil? || lines.size > MAX_LINES || lines.any? { |line| line[:content].blank? }
    return false if lines.any? do |line|
      line[:content].match?(profile.ocr_reference_pricing_line_group_discount_conflict_pattern)
    end

    price_field = item.dig("valueObject", "Price")
    price_content = safe_content(price_field&.fetch("content", nil), maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    price_span = single_span(price_field)
    return false unless exact_provider_content?(price_content, price_span, maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    return false unless span_within?(price_span, parent_span)

    price_content = price_content.unicode_normalize(:nfkc).strip
    return false if price_content.blank? || price_content.match?(LINE_BREAK_PATTERN)
    discount_line_indexes = lines.each_index.select do |index|
      lines.fetch(index).fetch(:content).match?(profile.ocr_item_discount_keyword_pattern)
    end
    return false unless discount_line_indexes.one?

    label_index = discount_line_indexes.sole
    return false unless promotional_discount_label?(lines.fetch(label_index).fetch(:content))

    price_line_indexes = lines.each_index.select do |index|
      span_within?(price_span, lines.fetch(index).fetch(:provider_span))
    end
    return false unless price_line_indexes.one?

    price_line_index = price_line_indexes.sole
    return false unless lines.fetch(price_line_index).fetch(:content) == price_content
    notes = lines.each_index.filter_map do |index|
      match = profile.ocr_reference_pricing_item_layout_per_unit_discount_note_pattern.match(
        lines.fetch(index).fetch(:content)
      )
      [ index, match ] if match
    end
    return false unless notes.one?

    note_index, note_match = notes.sole
    return false unless price_line_index == label_index + 1
    return false unless note_index == price_line_index + 1

    promotional_note_matches_reference?(note_match, reference_candidate)
  rescue ArgumentError, EncodingError, IndexError, TypeError
    false
  end

  def exact_promotional_reference_candidate(item, item_index)
    matches = reference_pricing_candidates.select do |candidate|
      candidate[:candidate_id] == "azure_items_#{item_index}_reference_pricing" &&
        candidate[:item_index] == item_index
    end
    return unless matches.one?

    candidate = matches.sole
    return unless candidate[:validation_state] == "valid"
    return unless Array(candidate[:rejection_reasons]).empty?
    return unless candidate[:reference_price_tax_inclusion] == "gross"
    return unless candidate.dig(:tax_inclusion_evidence, :kind) ==
      "single_item_receipt_inner_tax_summary"
    return unless candidate.dig(:reference_quantity, :origin) == "implicit_per_unit"
    return unless reference_component_path?(candidate, :reference_price, item_index, "Price")
    return unless reference_component_path?(candidate, :reference_quantity, item_index, "QuantityUnit")
    return unless reference_component_path?(candidate, :purchased_quantity, item_index, "Quantity")
    return unless reference_component_path?(candidate, :printed_line_total, item_index, "TotalPrice")
    return unless candidate.dig(:corroboration, :projected_amount).to_s ==
      candidate.dig(:printed_line_total, :amount).to_s
    return unless candidate.dig(:corroboration, :printed_line_total).to_s ==
      candidate.dig(:printed_line_total, :amount).to_s
    return unless promotional_reference_candidate_matches_item?(candidate, item)

    candidate
  end

  def promotional_reference_candidate_matches_item?(candidate, item)
    fields = item["valueObject"]
    return false unless fields.is_a?(Hash)

    price = provider_decimal(fields.dig("Price", "valueCurrency", "amount"))
    quantity = provider_decimal(fields.dig("Quantity", "valueNumber"))
    total = provider_decimal(fields.dig("TotalPrice", "valueCurrency", "amount"))
    unit = profile.resolve_quantity_unit(fields.dig("QuantityUnit", "valueString"))
    price == lexeme_decimal(candidate.dig(:reference_price, :amount)) &&
      quantity == lexeme_decimal(candidate.dig(:purchased_quantity, :amount)) &&
      total == lexeme_decimal(candidate.dig(:printed_line_total, :amount)) &&
      unit&.code == candidate.dig(:purchased_quantity, :unit_code)
  end

  def promotional_discount_label?(line)
    line.match?(profile.ocr_item_discount_keyword_pattern) &&
      !line.match?(PROMOTIONAL_DISCOUNT_LABEL_VALUE_PATTERN)
  end

  def promotional_note_matches_reference?(match, candidate)
    basis_quantity = lexeme_decimal(match[:basis_quantity].presence || "1")
    reference_quantity = lexeme_decimal(candidate.dig(:reference_quantity, :amount))
    unit = profile.resolve_quantity_unit(match[:unit])

    basis_quantity && reference_quantity && basis_quantity == reference_quantity &&
      unit&.code == candidate.dig(:reference_quantity, :unit_code)
  end

  def reference_component_path?(candidate, component, item_index, field_name)
    candidate.dig(component, :evidence, :source_field_path) ==
      "documents[0].fields.Items[#{item_index}].#{field_name}"
  end

  def provider_content_lines(value, parent_span)
    return unless parent_span

    parts = value.split(LINE_BREAK_CAPTURE_PATTERN, -1)
    provider_offset = parent_span.begin
    lines = parts.each_slice(2).map do |line, separator|
      line_length = mapper.length(line)
      line_span = provider_offset...(provider_offset + line_length)
      provider_offset = line_span.end
      provider_offset += mapper.length(separator) if separator
      { content: line.strip, provider_span: line_span }
    end
    return unless provider_offset == parent_span.end

    lines
  rescue ArgumentError, EncodingError, TypeError
    nil
  end

  def component_evidence(field_path, span)
    {
      source_field_path: field_path,
      provider_span_start: span.begin,
      provider_span_end: span.end
    }
  end

  def description_component(field, parent_span:, field_path:)
    return unless field.is_a?(Hash)

    value_string = safe_content(field["valueString"], maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    field_content = safe_content(field["content"], maximum_bytes: MAX_FIELD_CONTENT_BYTES)
    span = single_span(field)
    return if value_string.blank? || field_content.blank? || value_string != field_content
    return unless span_within?(span, parent_span)
    return unless exact_provider_content?(field_content, span, maximum_bytes: MAX_FIELD_CONTENT_BYTES)

    { evidence: component_evidence(field_path, span) }
  end

  def option_evidence_overlaps?(left, right)
    evidence_ranges(left.fetch(:evidence)).product(evidence_ranges(right.fetch(:evidence))).any? do |a, b|
      ranges_overlap?(a, b)
    end
  end

  def nonoverlapping_evidence?(*evidence)
    ranges = evidence.map { |entry| evidence_range(entry) }
    return false if ranges.any?(&:nil?)

    ranges.combination(2).none? { |left, right| ranges_overlap?(left, right) }
  end

  def evidence_ranges(value)
    value.values.filter_map { |entry| evidence_range(entry) }
  end

  def evidence_range(value)
    value = normalized_hash(value)
    start_value = value[:provider_span_start]
    end_value = value[:provider_span_end]
    return unless start_value.is_a?(Integer) && end_value.is_a?(Integer) && end_value > start_value

    (start_value...end_value)
  end

  def item_field_path(item_index, field_name = nil)
    path = "documents[0].fields.Items[#{item_index}]"
    field_name ? "#{path}.#{field_name}" : path
  end

  def item_identity(item_index, parent_span)
    "azure_structured_item_i#{item_index}_s#{parent_span.begin}_e#{parent_span.end}"
  end

  def overlapping_parent_indexes(parent_spans)
    sorted = parent_spans.each_with_index.filter_map do |span, index|
      [ span, index ] if span
    end.sort_by { |span, _index| [ span.begin, span.end ] }
    overlapping = Set.new

    sorted.each_with_index do |(left_span, left_index), position|
      sorted.drop(position + 1).each do |right_span, right_index|
        break if right_span.begin >= left_span.end
        next unless ranges_overlap?(left_span, right_span)

        overlapping << left_index << right_index
      end
    end

    overlapping
  end

  def ranges_overlap?(left, right)
    left.begin < right.end && right.begin < left.end
  end

  def single_span(value)
    spans = value.is_a?(Hash) ? value["spans"] : nil
    return unless spans.is_a?(Array) && spans.one?

    span = spans.sole
    return unless span.is_a?(Hash)

    offset = span["offset"]
    length = span["length"]
    return unless offset.is_a?(Integer) && offset.between?(0, MAX_PROVIDER_SPAN_VALUE)
    return unless length.is_a?(Integer) && length.positive?
    return if length > MAX_PROVIDER_SPAN_VALUE - offset

    (offset...(offset + length))
  end

  def span_within?(child, parent)
    child && parent && child.begin >= parent.begin && child.end <= parent.end
  end

  def safe_content(value, maximum_bytes:)
    return unless value.is_a?(String)
    return if value.bytesize > maximum_bytes
    return unless value.encoding == Encoding::UTF_8 || value.encoding == Encoding::US_ASCII
    return unless value.valid_encoding?
    return if value.match?(CONTROL_CHARACTER_PATTERN)

    value
  end

  def exact_provider_content?(value, span, maximum_bytes:)
    value = safe_content(value, maximum_bytes: maximum_bytes)
    return false if value.nil? || span.nil?
    return false unless mapper.length(value) == span.size

    mapper.slice(content, offset: span.begin, length: span.size) == value
  rescue ArgumentError, EncodingError, TypeError
    false
  end

  def normalized_hash(value)
    value.respond_to?(:with_indifferent_access) ? value.with_indifferent_access : {}.with_indifferent_access
  end
end
