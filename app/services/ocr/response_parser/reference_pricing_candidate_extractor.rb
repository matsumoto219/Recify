class Ocr::ResponseParser::ReferencePricingCandidateExtractor
  MAX_ITEMS = 100
  MAX_ITEM_CONTENT_BYTES = 4_096
  MAX_FIELD_CONTENT_BYTES = 512
  MAX_COMPONENT_SPANS = 16
  MAX_REFERENCE_EXPRESSION_MATCHES = MAX_COMPONENT_SPANS
  MAX_PURCHASED_QUANTITY_MATCHES = MAX_COMPONENT_SPANS
  MAX_REJECTION_REASONS = 8
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  MAX_PRICE_AMOUNT = BigDecimal("999999999999")
  MAX_QUANTITY = BigDecimal("9999.999")
  MAX_PRICE_SCALE = 6
  MAX_QUANTITY_SCALE = 3

  REJECTION_REASONS = %w[
    missing_reference_price
    missing_reference_quantity
    missing_reference_unit
    missing_purchased_quantity
    missing_purchased_unit
    ambiguous_reference_expression
    ambiguous_purchased_quantity
    ambiguous_tax_inclusion
    unsupported_reference_unit
    unsupported_purchased_unit
    incompatible_unit_dimension
    invalid_reference_price
    invalid_reference_quantity
    invalid_purchased_quantity
    reference_price_out_of_bounds
    reference_quantity_out_of_bounds
    purchased_quantity_out_of_bounds
    evidence_outside_item
    insufficient_component_evidence
  ].freeze
  UNSUPPORTED_REASONS = %w[
    unsupported_reference_unit
    unsupported_purchased_unit
    incompatible_unit_dimension
    invalid_reference_price
    invalid_reference_quantity
    invalid_purchased_quantity
    reference_price_out_of_bounds
    reference_quantity_out_of_bounds
    purchased_quantity_out_of_bounds
    evidence_outside_item
    insufficient_component_evidence
  ].freeze
  AMBIGUOUS_REASONS = %w[
    ambiguous_reference_expression
    ambiguous_purchased_quantity
    ambiguous_tax_inclusion
  ].freeze
  MISSING_REASONS = %w[
    missing_reference_price
    missing_reference_quantity
    missing_reference_unit
    missing_purchased_quantity
    missing_purchased_unit
  ].freeze

  DECIMAL_SOURCE = "(?:[0-9０-９]{1,3}(?:[,，][0-9０-９]{3})+|[0-9０-９]+)(?:[.．][0-9０-９]+)?"
  UNIT_SOURCE = "[\\p{L}]{1,24}"
  INCOMPLETE_REFERENCE_PATTERN = Regexp.new(
    "[（(]?[ \\t]*(?:[¥￥][ \\t]*(?<price_prefix>#{DECIMAL_SOURCE})[ \\t]*(?:円)?|" \
      "(?<price_suffix>#{DECIMAL_SOURCE})[ \\t]*円)[ \\t]*[/／][ \\t]*" \
      "(?<reference_quantity>#{DECIMAL_SOURCE})[ \\t]*(?![\\p{L}])",
    Regexp::FIXEDENCODING
  ).freeze
  PURCHASED_QUANTITY_PATTERN = /(?<![0-9０-９])(?<quantity>#{DECIMAL_SOURCE})[ \t]*(?<unit>#{UNIT_SOURCE})/u
  PRINTED_AMOUNT_PATTERN = /[¥￥]?[ \t]*(?<amount>#{DECIMAL_SOURCE})(?:[ \t]*円)?/u
  DECIMAL_TOKEN_PATTERN = /(?<![0-9０-９])(?<decimal>#{DECIMAL_SOURCE})(?![0-9０-９])/u
  UNIT_TOKEN_PATTERN = /#{UNIT_SOURCE}/u
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u0084\u0086-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\n\r\u0085\u2028\u2029]/.freeze

  def self.call(
    items:,
    profile:,
    content: nil,
    string_index_type: "utf16CodeUnit",
    projection: nil,
    allow_separated_tax_label: false
  )
    new(
      items:,
      profile:,
      content:,
      string_index_type:,
      projection:,
      allow_separated_tax_label:
    ).call
  end

  def initialize(
    items:,
    profile:,
    content: nil,
    string_index_type: "utf16CodeUnit",
    projection: nil,
    allow_separated_tax_label: false
  )
    @items = items
    @profile = profile
    @allow_separated_tax_label = allow_separated_tax_label
    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: string_index_type)
    @provider_content_supplied = !content.nil?
    @provider_content = raw_mappable_text(
      content,
      max_bytes: Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
    )&.freeze if @provider_content_supplied
    @projection = projection || ->(**attributes) {
      ReceiptAmountService.reference_item_extension_projection(**attributes)
    }
  end

  def call
    return [] if mapper.nil?
    return [] if provider_content_supplied && provider_content.nil?
    return [] unless items.is_a?(Array)

    bounded_items = items.first(MAX_ITEMS)
    parent_span_sets = bounded_items.map do |item|
      item.is_a?(Hash) ? bounded_parent_spans(item) : nil
    rescue EncodingError, TypeError, ArgumentError
      nil
    end
    item_contexts = bounded_items.map.with_index do |item, item_index|
      item.is_a?(Hash) ? build_item_context(item, spans: parent_span_sets[item_index]) : nil
    rescue EncodingError, TypeError, ArgumentError
      nil
    end
    candidates = bounded_items.filter_map.with_index do |item, item_index|
      extract_candidate(item, item_index, item_contexts[item_index])
    rescue EncodingError, TypeError, ArgumentError
      nil
    end

    mark_item_identity_conflicts(candidates, parent_span_sets)
  end

  private

  attr_reader :items, :mapper, :profile, :projection, :provider_content,
    :provider_content_supplied, :allow_separated_tax_label

  def extract_candidate(item, item_index, item_context)
    return unless item.is_a?(Hash) && item_context

    value_object = item["valueObject"]
    value_object = {} unless value_object.is_a?(Hash)
    reference_matches, evidence_errors = reference_matches(
      value_object,
      item_context,
      item_index
    )
    return if reference_matches.empty?

    reasons = evidence_errors
    reasons << "ambiguous_reference_expression" if reference_matches.many?
    reference_match = reference_matches.first

    reference_price, price_reasons = reference_price_component(reference_match)
    reference_quantity, reference_quantity_reasons = reference_quantity_component(reference_match)
    reasons.concat(price_reasons).concat(reference_quantity_reasons)

    purchased_matches, purchased_evidence_errors = purchased_quantity_matches(
      value_object,
      item_context,
      item_index,
      reference_match
    )
    reasons.concat(purchased_evidence_errors)
    reasons << "ambiguous_purchased_quantity" if purchased_matches.many?
    purchased_match = purchased_matches.first
    purchased_quantity, purchased_reasons = purchased_quantity_component(purchased_match)
    reasons.concat(purchased_reasons)

    tax_inclusion, tax_evidence, tax_reasons = tax_inclusion(reference_match)
    reasons.concat(tax_reasons)

    if reference_quantity&.dig(:unit_code).present? && purchased_quantity&.dig(:unit_code).present? &&
        !ReceiptQuantityUnit.convertible?(
          from: purchased_quantity[:unit_code],
          to: reference_quantity[:unit_code]
        )
      reasons << "incompatible_unit_dimension"
    end

    printed_line_total = printed_line_total_component(value_object, item_context, item_index)
    reasons.concat(structured_value_conflict_reasons(
      value_object: value_object,
      reference_price: reference_price,
      purchased_quantity: purchased_quantity,
      printed_line_total: printed_line_total
    ))
    reasons = normalize_reasons(reasons)
    corroboration = build_corroboration(
      reference_price:,
      reference_quantity:,
      purchased_quantity:,
      printed_line_total:,
      reasons:
    )
    if reference_match[:structured_unit_price] &&
        (!corroboration.is_a?(Hash) || Array(corroboration[:rounding_matches]).empty?)
      return
    end

    {
      candidate_id: "azure_items_#{item_index}_reference_pricing",
      item_index: item_index,
      validation_state: validation_state(reasons),
      rejection_reasons: reasons,
      reference_price: reference_price,
      reference_quantity: reference_quantity,
      purchased_quantity: purchased_quantity,
      reference_price_tax_inclusion: tax_inclusion,
      tax_inclusion_evidence: tax_evidence,
      printed_line_total: printed_line_total,
      corroboration: corroboration
    }
  end

  def reference_matches(value_object, item_context, item_index)
    matches = []
    evidence_errors = []
    raw_match_budget = { remaining: MAX_REFERENCE_EXPRESSION_MATCHES, exceeded: false }
    price_field = value_object["Price"]
    discount_price_span = nil
    field_match_kind = nil

    if price_field.is_a?(Hash) && content_supplied?(price_field["content"])
      mapped_price = bounded_structured_field(price_field, item_context:)

      if mapped_price.nil?
        evidence_errors << "evidence_outside_item"
      else
        field_content = mapped_price.fetch(:content)
        field_span = mapped_price.fetch(:span)
        price_matches = scan_reference_expressions(
          field_content,
          base_offset: span_offset(field_span),
          source_field_path: "documents[0].fields.Items[#{item_index}].Price",
          item_index: item_index,
          item_context: item_context,
          priority: 0,
          raw_match_budget: raw_match_budget
        )
        if discount_adjustment_text?(field_content)
          discount_price_span = field_span
        else
          matches.concat(price_matches)
          field_match_kind = :explicit_price if price_matches.any?
        end
      end
    end

    if matches.empty?
      structured_match = structured_measurement_unit_price_match(
        value_object:,
        item_context:,
        item_index:
      )
      if structured_match
        matches << structured_match
        field_match_kind = :structured
      end
    end

    item_matches = item_context.fetch(:segments).flat_map do |segment|
      scan_reference_expressions(
        segment.fetch(:content),
        base_offset: span_offset(segment.fetch(:span)),
        source_field_path: "documents[0].fields.Items[#{item_index}]",
        item_index: item_index,
        item_context: item_context,
        priority: 1,
        raw_match_budget: raw_match_budget
      )
    end
    if discount_price_span
      item_matches.reject! do |match|
        ranges_overlap?(
          match[:expression_start], match[:expression_end],
          span_offset(discount_price_span), span_end(discount_price_span)
        )
      end
    end
    if field_match_kind == :structured
      item_matches.reject! { |match| match[:discount_context] }
    elsif field_match_kind.nil? && structured_measurement_context?(
      value_object,
      item_context:,
      item_index:
    )
      item_matches.reject! { |match| match[:discount_context] }
    end
    matches.concat(item_matches)

    evidence_errors << "ambiguous_reference_expression" if raw_match_budget[:exceeded]

    if matches.empty?
      incomplete = scan_incomplete_reference_expression(
        price_field,
        item_context: item_context,
        item_index: item_index
      )
      matches << incomplete if incomplete
    end

    [ deduplicate_reference_matches(matches), evidence_errors ]
  end

  def scan_incomplete_reference_expression(price_field, item_context:, item_index:)
    mapped_price = price_field.is_a?(Hash) ?
      bounded_structured_field(price_field, item_context:) : nil
    if mapped_price
      field_content = mapped_price.fetch(:content)
      field_span = mapped_price.fetch(:span)
      match_data = field_content.match(INCOMPLETE_REFERENCE_PATTERN)
      return build_incomplete_reference_match(
        match_data,
        field_content,
        base_offset: span_offset(field_span),
        source_field_path: "documents[0].fields.Items[#{item_index}].Price",
        item_index: item_index,
        priority: 0
      ) if match_data
    end

    item_context.fetch(:segments).each do |segment|
      segment_content = segment.fetch(:content)
      match_data = segment_content.match(INCOMPLETE_REFERENCE_PATTERN)
      next unless match_data

      return build_incomplete_reference_match(
        match_data,
        segment_content,
        base_offset: span_offset(segment.fetch(:span)),
        source_field_path: "documents[0].fields.Items[#{item_index}]",
        item_index: item_index,
        priority: 1
      )
    end

    nil
  end

  def build_incomplete_reference_match(match_data, text, base_offset:, source_field_path:, item_index:, priority:)
    price_capture = match_data[:price_prefix].present? ? :price_prefix : :price_suffix
    reference_start = match_data.begin(:reference_quantity)
    local_window = local_expression_line(text, match_data.begin(0), match_data.end(0))
    matched_tax = tax_basis_labels.values.flatten.find { |label| local_window.include?(label) }
    tax_local_start = matched_tax ? local_window.index(matched_tax) : nil
    line_start = previous_line_break_index(text, match_data.begin(0))
    tax_start = tax_local_start ? (line_start ? line_start + 1 : 0) + tax_local_start : nil

    {
      expression_text: match_data[0],
      expression_start: provider_offset(text, base_offset, match_data.begin(0)),
      expression_end: provider_offset(text, base_offset, match_data.end(0)),
      price_text: match_data[price_capture],
      price_evidence: evidence(
        source_field_path: source_field_path,
        item_index: item_index,
        start_offset: provider_offset(text, base_offset, match_data.begin(price_capture)),
        end_offset: provider_offset(text, base_offset, match_data.end(price_capture))
      ),
      reference_quantity_text: match_data[:reference_quantity],
      reference_unit_text: nil,
      reference_quantity_evidence: evidence(
        source_field_path: source_field_path,
        item_index: item_index,
        start_offset: provider_offset(text, base_offset, reference_start),
        end_offset: provider_offset(text, base_offset, match_data.end(:reference_quantity))
      ),
      tax_text: matched_tax,
      tax_evidence: matched_tax ? evidence(
        source_field_path: source_field_path,
        item_index: item_index,
        start_offset: provider_offset(text, base_offset, tax_start),
        end_offset: provider_offset(text, base_offset, tax_start + matched_tax.length)
      ) : nil,
      tax_window_text: local_window,
      priority: priority,
      source_text: text
    }
  end

  def scan_reference_expressions(
    text,
    base_offset:,
    source_field_path:,
    item_index:,
    item_context:,
    priority:,
    raw_match_budget:
  )
    matches = []
    text.scan(reference_expression_pattern) do
      if raw_match_budget[:remaining].zero?
        raw_match_budget[:exceeded] = true
        break
      end

      raw_match_budget[:remaining] -= 1
      match_data = Regexp.last_match
      match = build_reference_match(
        match_data,
        text,
        base_offset:,
        source_field_path:,
        item_index:,
        priority:
      )
      matches << match if range_within_parent?(match[:expression_start], match[:expression_end], item_context)
    end

    matches
  end

  def structured_measurement_unit_price_match(value_object:, item_context:, item_index:)
    fields = %w[Price Quantity QuantityUnit TotalPrice].to_h do |field_name|
      [ field_name, value_object[field_name] ]
    end
    return unless fields.values.all? { |field| field.is_a?(Hash) }

    price = structured_decimal_lexeme(
      fields.fetch("Price"),
      item_context:,
      item_index:,
      field_name: "Price"
    )
    purchased = structured_decimal_lexeme(
      fields.fetch("Quantity"),
      item_context:,
      item_index:,
      field_name: "Quantity"
    )
    printed_total = structured_decimal_lexeme(
      fields.fetch("TotalPrice"),
      item_context:,
      item_index:,
      field_name: "TotalPrice"
    )
    unit = structured_measurement_unit_lexeme(
      fields.fetch("QuantityUnit"),
      item_context:,
      item_index:
    )
    return if [ price, purchased, printed_total, unit ].any?(&:nil?)
    return if discount_adjustment_text?(price[:content])
    return if structured_quantity_conflicts_with_description?(
      value_object["Description"],
      purchased:,
      unit:,
      purchased_span: purchased[:field_span],
      unit_span: unit[:field_span],
      item_context:
    )
    return unless structured_currency_value_matches?(fields.fetch("Price"), price[:amount])
    return unless structured_number_value_matches?(fields.fetch("Quantity"), purchased[:amount])
    return unless structured_unit_value_matches?(fields.fetch("QuantityUnit"), unit[:unit_code])
    return unless structured_currency_value_matches?(fields.fetch("TotalPrice"), printed_total[:amount])
    return unless structured_formula_agrees?(price:, purchased:, unit:, printed_total:)

    tax_text, tax_evidence = structured_price_tax_evidence(
      price,
      item_index:
    )
    evidence_ranges = [ price[:evidence], unit[:evidence] ]

    {
      expression_text: price[:content],
      expression_start: evidence_ranges.map { |entry| entry[:provider_span_start] }.min,
      expression_end: evidence_ranges.map { |entry| entry[:provider_span_end] }.max,
      price_text: price[:amount],
      price_evidence: price[:evidence],
      reference_quantity_text: nil,
      reference_unit_text: unit[:text],
      reference_quantity_evidence: unit[:evidence],
      tax_text: tax_text,
      tax_evidence: tax_evidence,
      tax_window_text: price[:content],
      priority: 0,
      source_text: price[:content],
      discount_context: false,
      structured_unit_price: true,
      structured_purchased_match: {
        quantity_text: purchased[:amount],
        unit_text: unit[:text],
        evidence: purchased[:evidence],
        priority: 0
      }
    }
  end

  def structured_measurement_context?(value_object, item_context:, item_index:)
    fields = %w[Quantity QuantityUnit TotalPrice].to_h do |field_name|
      [ field_name, value_object[field_name] ]
    end
    return false unless fields.values.all? { |field| field.is_a?(Hash) }

    purchased = structured_decimal_lexeme(
      fields.fetch("Quantity"),
      item_context:,
      item_index:,
      field_name: "Quantity"
    )
    printed_total = structured_decimal_lexeme(
      fields.fetch("TotalPrice"),
      item_context:,
      item_index:,
      field_name: "TotalPrice"
    )
    unit = structured_measurement_unit_lexeme(
      fields.fetch("QuantityUnit"),
      item_context:,
      item_index:
    )
    return false if [ purchased, printed_total, unit ].any?(&:nil?)
    return false if structured_quantity_conflicts_with_description?(
      value_object["Description"],
      purchased:,
      unit:,
      purchased_span: purchased[:field_span],
      unit_span: unit[:field_span],
      item_context:
    )

    structured_number_value_matches?(fields.fetch("Quantity"), purchased[:amount]) &&
      structured_unit_value_matches?(fields.fetch("QuantityUnit"), unit[:unit_code]) &&
      structured_currency_value_matches?(fields.fetch("TotalPrice"), printed_total[:amount])
  end

  def structured_decimal_lexeme(field, item_context:, item_index:, field_name:)
    mapped_field = exact_structured_field(field, item_context:)
    return if mapped_field.nil?

    content = mapped_field.fetch(:content)
    span = mapped_field.fetch(:span)

    matches = []
    content.scan(DECIMAL_TOKEN_PATTERN) do
      match_data = Regexp.last_match
      amount = canonical_decimal(match_data[:decimal])
      return if amount.nil?

      matches << {
        amount:,
        start_index: match_data.begin(:decimal),
        end_index: match_data.end(:decimal)
      }
      return if matches.many?
    end
    return unless matches.one?

    match = matches.sole
    match.merge(
      content:,
      field_span: span,
      field_span_offset: span_offset(span),
      evidence: evidence(
        source_field_path: "documents[0].fields.Items[#{item_index}].#{field_name}",
        item_index:,
        start_offset: provider_offset(content, span_offset(span), match[:start_index]),
        end_offset: provider_offset(content, span_offset(span), match[:end_index])
      )
    )
  end

  def structured_measurement_unit_lexeme(field, item_context:, item_index:)
    mapped_field = exact_structured_field(field, item_context:)
    return if mapped_field.nil?

    content = mapped_field.fetch(:content)
    span = mapped_field.fetch(:span)

    matches = []
    content.scan(UNIT_TOKEN_PATTERN) do
      match_data = Regexp.last_match
      resolution = resolve_unit(match_data[0])
      unit = resolution.known? ? ReceiptQuantityUnit.unit_for(resolution.code) : nil
      next unless unit&.kind == :decimal
      next unless unit.allows_pricing_role?(:purchased) && unit.allows_pricing_role?(:reference)

      matches << {
        text: match_data[0],
        unit_code: resolution.code,
        start_index: match_data.begin(0),
        end_index: match_data.end(0)
      }
      return if matches.many?
    end
    return unless matches.one?

    match = matches.sole
    match.merge(
      field_span: span,
      evidence: evidence(
        source_field_path: "documents[0].fields.Items[#{item_index}].QuantityUnit",
        item_index:,
        start_offset: provider_offset(content, span_offset(span), match[:start_index]),
        end_offset: provider_offset(content, span_offset(span), match[:end_index])
      )
    )
  end

  def structured_currency_value_matches?(field, lexical_amount)
    currency = field["valueCurrency"]
    return false unless currency.is_a?(Hash) && currency.key?("amount")

    return false unless currency["currencyCode"] == "JPY"

    structured_decimal_value(currency["amount"]) == BigDecimal(lexical_amount)
  rescue ArgumentError, TypeError
    false
  end

  def exact_structured_field(field, item_context:)
    mapped_field = bounded_structured_field(field, item_context:)
    return if mapped_field.nil?

    content = mapped_field.fetch(:content)
    span = mapped_field.fetch(:span)
    return unless provider_length(content) == span_length(span)
    return unless provider_slice_for_span(span, item_context) == content
    return unless exact_top_level_content?(raw_mappable_text(field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES), span)

    mapped_field
  end

  def bounded_structured_field(field, item_context:)
    content = normalized_mappable_text(field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES)
    span = single_span(field)
    return if content.blank? || span.nil? || !span_within?(span, item_context)
    return unless provider_length(content) <= span_length(span)
    return { content:, span: } unless provider_content_supplied || item_context.fetch(:spans).many?

    return unless provider_length(content) == span_length(span)
    return unless provider_slice_for_span(span, item_context) == content
    return unless exact_top_level_content?(raw_mappable_text(field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES), span)

    { content:, span: }
  end

  def provider_slice_for_span(span, item_context)
    segment = segment_containing_range(item_context, span_offset(span), span_end(span))
    return if segment.nil?

    relative_offset = span_offset(span) - span_offset(segment.fetch(:span))
    return if relative_offset.negative?

    mapper.slice(segment.fetch(:content), offset: relative_offset, length: span_length(span))
  rescue EncodingError, ArgumentError
    nil
  end

  def structured_quantity_conflicts_with_description?(
    description_field,
    purchased:,
    unit:,
    purchased_span:,
    unit_span:,
    item_context:
  )
    return true if description_field.nil?
    return true unless description_field.is_a?(Hash)

    description = exact_structured_field(description_field, item_context:)
    return true if description.nil?

    overlaps_description = [ purchased_span, unit_span ].any? do |quantity_span|
      ranges_overlap?(
        span_offset(description[:span]), span_end(description[:span]),
        span_offset(quantity_span), span_end(quantity_span)
      )
    end
    return true if overlaps_description

    description[:content].scan(description_quantity_pattern) do
      match_data = Regexp.last_match
      amount = canonical_decimal(match_data[:quantity])
      resolution = resolve_unit(match_data[:unit])
      next if amount.nil? || !resolution.known?
      next unless ReceiptQuantityUnit.convertible?(from: resolution.code, to: unit[:unit_code])

      converted = ReceiptQuantityUnit.convert_exact(
        BigDecimal(amount),
        from: resolution.code,
        to: unit[:unit_code]
      )
      return true if converted == BigDecimal(purchased[:amount]).to_r
    end

    false
  rescue ArgumentError, TypeError
    true
  end

  def description_quantity_pattern
    @description_quantity_pattern ||= begin
      aliases = profile.quantity_unit_aliases.keys.map(&:to_s).reject(&:empty?).uniq
        .sort_by { |value| [ -value.length, value ] }
      unit_source = Regexp.union(aliases).source

      Regexp.new(
        "(?<![0-9０-９])(?<quantity>#{DECIMAL_SOURCE})[ \\t]*(?<unit>#{unit_source})" \
          "(?![A-Za-zＡ-Ｚａ-ｚ])",
        Regexp::FIXEDENCODING
      )
    end
  end

  def structured_number_value_matches?(field, lexical_amount)
    return false unless field.key?("valueNumber")

    structured_decimal_value(field["valueNumber"]) == BigDecimal(lexical_amount)
  rescue ArgumentError, TypeError
    false
  end

  def structured_unit_value_matches?(field, lexical_unit_code)
    return false unless field.key?("valueString")

    resolution = resolve_unit(field["valueString"])
    resolution.known? && resolution.code == lexical_unit_code
  end

  def structured_formula_agrees?(price:, purchased:, unit:, printed_total:)
    result = projection.call(
      reference_price_amount: price[:amount],
      reference_quantity: "1",
      reference_unit_code: unit[:unit_code],
      purchased_quantity: purchased[:amount],
      purchased_unit_code: unit[:unit_code]
    )
    exact_amount = result.fetch(:exact_amount).to_r
    printed_amount = Rational(printed_total[:amount])

    rounding_matches(exact_amount, printed_amount).any?
  rescue ReceiptAmountService::InvalidItemSourceError, ArgumentError, KeyError, TypeError
    false
  end

  def discount_context_for_expression(text, expression_start, local_window)
    return :same_line if discount_adjustment_text?(local_window)
    return if tax_basis_labels.values.flatten.any? { |label| local_window.include?(label) }

    line_start = previous_line_break_index(text, expression_start)
    return if line_start.nil?

    matched = text[0...line_start].to_s.split(LINE_BREAK_PATTERN).last(3).any? do |line|
      discount_adjustment_text?(line)
    end
    :preceding if matched
  rescue EncodingError, TypeError
    nil
  end

  def discount_adjustment_text?(text)
    text.match?(profile.ocr_item_discount_keyword_pattern) &&
      !text.match?(profile.ocr_post_discount_price_basis_pattern)
  end

  def structured_price_tax_evidence(price, item_index:)
    labels = tax_label_matches(price[:content])
    return [ nil, nil ] unless labels.map { |entry| entry[:inclusion] }.uniq.one?

    match = labels.min_by { |entry| [ entry[:index], -entry[:label].length ] }
    label = match.fetch(:label)
    index = match.fetch(:index)
    [
      label,
      evidence(
        source_field_path: "documents[0].fields.Items[#{item_index}].Price",
        item_index:,
        start_offset: provider_offset(
          price[:content],
          price[:field_span_offset],
          index
        ),
        end_offset: provider_offset(
          price[:content],
          price[:field_span_offset],
          index + label.length
        )
      )
    ]
  end

  def reference_expression_pattern
    @reference_expression_pattern ||= begin
      labels = tax_basis_labels.values.flatten
      tax_source = labels.empty? ? "(?!)" : Regexp.union(labels).source

      Regexp.new(
        "(?<tax_before>#{tax_source})?[ \\t]*[（(]?[ \\t]*" \
          "(?:[¥￥][ \\t]*(?<price_prefix>#{DECIMAL_SOURCE})[ \\t]*(?:円)?|" \
          "(?<price_suffix>#{DECIMAL_SOURCE})[ \\t]*円)[ \\t]*(?<tax_middle>#{tax_source})?[ \\t]*" \
          "[/／][ \\t]*(?<reference_quantity>#{DECIMAL_SOURCE})?[ \\t]*" \
          "(?<reference_unit>#{UNIT_SOURCE})[ \\t]*[)）]?[ \\t]*(?<tax_after>#{tax_source})?",
        Regexp::FIXEDENCODING
      )
    end
  end

  def build_reference_match(match_data, text, base_offset:, source_field_path:, item_index:, priority:)
    tax_capture = %i[tax_before tax_middle tax_after].find { |name| match_data[name].present? }
    price_capture = match_data[:price_prefix].present? ? :price_prefix : :price_suffix
    local_window = local_expression_line(text, match_data.begin(0), match_data.end(0))
    tax_text, tax_start, tax_end = local_tax_evidence(
      text,
      expression_start: match_data.begin(0),
      captured_tax: tax_capture ? match_data[tax_capture] : nil,
      captured_start: tax_capture ? match_data.begin(tax_capture) : nil,
      captured_end: tax_capture ? match_data.end(tax_capture) : nil
    )
    reference_quantity_start = if match_data[:reference_quantity].present?
      match_data.begin(:reference_quantity)
    else
      match_data.begin(:reference_unit)
    end

    {
      expression_text: match_data[0],
      expression_start: provider_offset(text, base_offset, match_data.begin(0)),
      expression_end: provider_offset(text, base_offset, match_data.end(0)),
      price_text: match_data[price_capture],
      price_evidence: evidence(
        source_field_path:,
        item_index:,
        start_offset: provider_offset(text, base_offset, match_data.begin(price_capture)),
        end_offset: provider_offset(text, base_offset, match_data.end(price_capture))
      ),
      reference_quantity_text: match_data[:reference_quantity],
      reference_unit_text: match_data[:reference_unit],
      reference_quantity_evidence: evidence(
        source_field_path:,
        item_index:,
        start_offset: provider_offset(text, base_offset, reference_quantity_start),
        end_offset: provider_offset(text, base_offset, match_data.end(:reference_unit))
      ),
      tax_text: tax_text,
      tax_evidence: tax_text ? evidence(
        source_field_path:,
        item_index:,
        start_offset: provider_offset(text, base_offset, tax_start),
        end_offset: provider_offset(text, base_offset, tax_end)
      ) : nil,
      tax_window_text: local_window,
      priority: priority,
      source_text: text,
      discount_context: discount_context_for_expression(
        text,
        match_data.begin(0),
        local_window
      )
    }
  end

  def local_tax_evidence(
    text,
    expression_start:,
    captured_tax:,
    captured_start:,
    captured_end:
  )
    if captured_tax.present?
      return [ nil, nil, nil ] unless tax_label_boundary?(text, captured_start, captured_end)

      return [ captured_tax, captured_start, captured_end ]
    end
    return [ nil, nil, nil ] unless allow_separated_tax_label

    line_start = previous_line_break_index(text, expression_start)
    line_content_start = line_start ? line_start + 1 : 0
    prefix = text[line_content_start...expression_start].to_s
    matches = tax_basis_labels.flat_map do |inclusion, labels|
      labels.filter_map do |label|
        match = prefix.match(
          /(?:\A|[ \t:：(（])(?<tax_label>#{Regexp.escape(label)})[ \t]*(?:[(（]?[0-9０-９]+(?:[.．][0-9０-９]+)?[%％][)）]?[ \t]*)?(?:[¥￥@＠][ \t]*)?\z/
        )
        next unless match

        index = match.begin(:tax_label)
        absolute_start = line_content_start + index
        next unless tax_label_boundary?(text, absolute_start, absolute_start + label.length)

        { inclusion:, label:, index: }
      end
    end
    return [ nil, nil, nil ] unless matches.map { |match| match[:inclusion] }.uniq.one?

    match = matches.min_by { |entry| [ entry[:index], -entry[:label].length ] }
    start_offset = line_content_start + match[:index]

    [ match[:label], start_offset, start_offset + match[:label].length ]
  end

  def tax_label_left_boundary?(text, start_offset)
    return false unless start_offset.is_a?(Integer) && start_offset >= 0
    return true if start_offset.zero?
    prefix = text[0...start_offset].to_s.unicode_normalize(:nfkc)
    return false if prefix.match?(profile.ocr_reference_pricing_tax_negation_prefix_pattern)

    text[start_offset - 1]&.match?(/[ \t\r\n:：(（]/)
  rescue EncodingError, ArgumentError
    false
  end

  def tax_label_boundary?(text, start_offset, end_offset)
    return false unless end_offset.is_a?(Integer) && end_offset >= start_offset
    return false unless tax_label_left_boundary?(text, start_offset)
    return true if end_offset == text.length

    text[end_offset]&.match?(%r{[ \t\r\n:：()（）¥￥@＠0-9０-９/／]})
  end

  def tax_label_matches(text)
    tax_basis_labels.flat_map do |inclusion, labels|
      labels.flat_map do |label|
        offset = 0
        matches = []
        while (index = text.index(label, offset))
          label_end = index + label.length
          if tax_label_boundary?(text, index, label_end)
            matches << { inclusion:, label:, index: }
          end
          offset = label_end
        end
        matches
      end
    end
  end

  def deduplicate_reference_matches(matches)
    matches.sort_by { |match| [ match[:priority], match[:expression_start], match[:expression_end] ] }
      .each_with_object([]) do |match, unique|
        duplicate = unique.find { |existing| same_reference_expression?(existing, match) }
        if duplicate
          if duplicate[:tax_text].blank? && match[:tax_text].present?
            duplicate[:tax_text] = match[:tax_text]
            duplicate[:tax_evidence] = match[:tax_evidence]
            duplicate[:expression_text] = match[:expression_text]
          end
        else
          unique << match
        end
      end
  end

  def same_reference_expression?(left, right)
    ranges_overlap?(
      left[:price_evidence][:provider_span_start], left[:reference_quantity_evidence][:provider_span_end],
      right[:price_evidence][:provider_span_start], right[:reference_quantity_evidence][:provider_span_end]
    ) &&
      canonical_decimal(left[:price_text]) == canonical_decimal(right[:price_text]) &&
      canonical_decimal(left[:reference_quantity_text] || "1") == canonical_decimal(right[:reference_quantity_text] || "1") &&
      normalized_unit_text(left[:reference_unit_text]) == normalized_unit_text(right[:reference_unit_text])
  end

  def reference_price_component(reference_match)
    amount = canonical_decimal(reference_match[:price_text])
    return [ nil, [ "invalid_reference_price" ] ] if amount.nil?

    reasons = decimal_reasons(
      amount,
      maximum: MAX_PRICE_AMOUNT,
      maximum_scale: MAX_PRICE_SCALE,
      invalid_reason: "invalid_reference_price",
      bounds_reason: "reference_price_out_of_bounds",
      allow_zero: true
    )

    [ { amount: amount, evidence: reference_match[:price_evidence] }, reasons ]
  end

  def reference_quantity_component(reference_match)
    amount = canonical_decimal(reference_match[:reference_quantity_text] || "1")
    return [ nil, [ "invalid_reference_quantity" ] ] if amount.nil?

    unit_resolution = resolve_unit(reference_match[:reference_unit_text])
    reasons = decimal_reasons(
      amount,
      maximum: MAX_QUANTITY,
      maximum_scale: MAX_QUANTITY_SCALE,
      invalid_reason: "invalid_reference_quantity",
      bounds_reason: "reference_quantity_out_of_bounds",
      allow_zero: false
    )
    reasons.concat(unit_reasons(unit_resolution, role: :reference))
    if unit_resolution.known? && !valid_unit_granularity?(amount, unit_resolution.code)
      reasons << "invalid_reference_quantity"
    end

    component = {
      amount: amount,
      unit_code: unit_resolution.code,
      unit_status: unit_resolution.status.to_s,
      origin: reference_match[:reference_quantity_text].present? ? "explicit" : "implicit_per_unit",
      evidence: reference_match[:reference_quantity_evidence]
    }
    component[:unit_raw] = bounded_unknown_unit_raw(unit_resolution) if unit_resolution.unknown?

    [ component, reasons ]
  end

  def purchased_quantity_matches(value_object, item_context, item_index, reference_match)
    if reference_match[:structured_purchased_match]
      return [ [ reference_match[:structured_purchased_match] ], [] ]
    end

    matches = []
    evidence_errors = []
    raw_match_budget = { remaining: MAX_PURCHASED_QUANTITY_MATCHES, exceeded: false }
    quantity_field = value_object["Quantity"]

    if quantity_field.is_a?(Hash) && content_supplied?(quantity_field["content"])
      mapped_quantity = bounded_structured_field(quantity_field, item_context:)

      if mapped_quantity.nil?
        evidence_errors << "evidence_outside_item"
      else
        quantity_content = mapped_quantity.fetch(:content)
        quantity_span = mapped_quantity.fetch(:span)
        structured_matches = scan_purchased_quantities(
          quantity_content,
          base_offset: span_offset(quantity_span),
          source_field_path: "documents[0].fields.Items[#{item_index}].Quantity",
          item_index:,
          item_context:,
          reference_end: reference_match[:expression_end],
          enforce_after_reference: false,
          priority: 0,
          raw_match_budget: raw_match_budget
        )
        if structured_matches.empty?
          numeric_only = quantity_content.match(/\A[ \t]*(?<quantity>#{DECIMAL_SOURCE})[ \t]*\z/u)
          if numeric_only
            structured_match = separate_structured_quantity_match(
              value_object,
              item_context:,
              item_index:,
              reference_match:
            ) || structured_quantity_without_unit_match(
              numeric_only,
              quantity_span: quantity_span,
              item_index: item_index
            )
            matches << structured_match
          end
        else
          matches.concat(structured_matches)
        end
      end
    end

    item_context.fetch(:segments).each do |segment|
      matches.concat(scan_purchased_quantities(
        segment.fetch(:content),
        base_offset: span_offset(segment.fetch(:span)),
        source_field_path: nil,
        item_index:,
        item_context:,
        reference_end: reference_match[:expression_end],
        enforce_after_reference: true,
        priority: 1,
        value_object: value_object,
        raw_match_budget: raw_match_budget
      ))
    end

    evidence_errors << "ambiguous_purchased_quantity" if raw_match_budget[:exceeded]

    [ deduplicate_purchased_matches(matches), evidence_errors ]
  end

  def separate_structured_quantity_match(value_object, item_context:, item_index:, reference_match:)
    quantity_field = value_object["Quantity"]
    unit_field = value_object["QuantityUnit"]
    return unless quantity_field.is_a?(Hash) && unit_field.is_a?(Hash)

    purchased = structured_decimal_lexeme(
      quantity_field,
      item_context:,
      item_index:,
      field_name: "Quantity"
    )
    unit = structured_measurement_unit_lexeme(
      unit_field,
      item_context:,
      item_index:
    )
    return if purchased.nil? || unit.nil?
    return unless provider_slice_for_span(unit[:field_span], item_context)&.strip == unit[:text]
    return unless structured_number_value_matches?(quantity_field, purchased[:amount])
    return unless structured_unit_value_matches?(unit_field, unit[:unit_code])
    return if structured_quantity_conflicts_with_description?(
      value_object["Description"],
      purchased:,
      unit:,
      purchased_span: purchased[:field_span],
      unit_span: unit[:field_span],
      item_context:
    )

    quantity_start = purchased.dig(:evidence, :provider_span_start)
    quantity_end = purchased.dig(:evidence, :provider_span_end)
    unit_start = unit.dig(:evidence, :provider_span_start)
    unit_end = unit.dig(:evidence, :provider_span_end)
    return if unit_start < quantity_end
    return if ranges_overlap?(
      quantity_start, unit_end,
      reference_match[:expression_start], reference_match[:expression_end]
    )

    containing_segment = segment_containing_range(item_context, quantity_start, unit_end)
    return if containing_segment.nil?

    gap = mapper.slice(
      containing_segment.fetch(:content),
      offset: quantity_end - span_offset(containing_segment.fetch(:span)),
      length: unit_start - quantity_end
    )
    return unless gap&.match?(/\A[ \t]*\z/)

    {
      quantity_text: purchased[:amount],
      unit_text: unit[:text],
      evidence: purchased[:evidence],
      priority: 0
    }
  end

  def scan_purchased_quantities(
    text,
    base_offset:,
    source_field_path:,
    item_index:,
    item_context:,
    reference_end:,
    enforce_after_reference:,
    priority:,
    value_object: nil,
    raw_match_budget:
  )
    matches = []
    line_break_offsets = nil
    text.scan(PURCHASED_QUANTITY_PATTERN) do
      if raw_match_budget[:remaining].zero?
        raw_match_budget[:exceeded] = true
        break
      end

      raw_match_budget[:remaining] -= 1
      match_data = Regexp.last_match
      global_start = provider_offset(text, base_offset, match_data.begin(:quantity))
      global_end = provider_offset(text, base_offset, match_data.end(:unit))
      next if enforce_after_reference && global_start < reference_end
      next unless range_within_parent?(global_start, global_end, item_context)
      next if package_quantity_context?(text, match_data)

      path = source_field_path || component_field_path_for_range(
        value_object,
        global_start,
        global_end,
        item_index,
        item_context
      )
      next if path.nil?
      next if path.end_with?(".Description") && !quantity_only_component_span?(
        value_object["Description"],
        global_start,
        global_end,
        item_context
      )
      if enforce_after_reference && path == "documents[0].fields.Items[#{item_index}]"
        line_break_offsets ||= provider_line_break_offsets(text, base_offset)
        next if line_break_between_provider_offsets?(line_break_offsets, reference_end, global_start)
      end

      matches << {
        quantity_text: match_data[:quantity],
        unit_text: match_data[:unit],
        evidence: evidence(
          source_field_path: path,
          item_index:,
          start_offset: global_start,
          end_offset: global_end
        ),
        priority: priority
      }
    end

    matches
  end

  def package_quantity_context?(text, match_data)
    before = text[[ match_data.begin(0) - 12, 0 ].max...match_data.begin(0)].to_s
    after = text[match_data.end(0), 6].to_s

    before.match?(profile.ocr_reference_pricing_package_quantity_context_before_pattern) ||
      after.match?(profile.ocr_reference_pricing_package_quantity_context_after_pattern)
  end

  def quantity_only_component_span?(field, start_offset, end_offset, item_context)
    return false unless field.is_a?(Hash)

    spans = bounded_component_spans(field, item_context:)
    return false unless spans&.many?

    spans.each_with_index.any? do |span, index|
      index.positive? && span_offset(span) == start_offset && span_end(span) >= end_offset
    end
  end

  def component_field_path_for_range(value_object, start_offset, end_offset, item_index, item_context)
    %w[Quantity Description QuantityUnit].each do |field_name|
      field = value_object[field_name]
      next unless field.is_a?(Hash)

      spans = bounded_component_spans(field, item_context:)
      return if spans.nil?
      return if field_name == "Description" && content_supplied?(field["content"]) && spans.empty?
      next unless spans.any? { |span| range_within_parent?(start_offset, end_offset, span) }

      return "documents[0].fields.Items[#{item_index}].#{field_name}"
    end

    "documents[0].fields.Items[#{item_index}]"
  end

  def bounded_component_spans(field, item_context:)
    spans = field["spans"]
    return [] if spans.nil?
    return unless spans.is_a?(Array) && spans.size <= MAX_COMPONENT_SPANS

    normalized = spans.map { |span| bounded_span(span) }
    return if normalized.any?(&:nil?)
    return if normalized.any? { |span| !span_within?(span, item_context) }

    normalized
  end

  def provider_line_break_offsets(text, base_offset)
    offsets = []
    byte_offset = 0

    text.each_char do |character|
      if character.match?(LINE_BREAK_PATTERN)
        span = mapper.span_for_bytes(text, byte_offset:, byte_length: 0)
        return if span.nil?

        offsets << base_offset + span.fetch(:offset)
      end
      byte_offset += character.bytesize
    end

    offsets
  end

  def line_break_between_provider_offsets?(line_break_offsets, start_offset, end_offset)
    return true unless line_break_offsets.is_a?(Array)

    line_break_offset = line_break_offsets.bsearch { |offset| offset >= start_offset }
    !line_break_offset.nil? && line_break_offset < end_offset
  end

  def deduplicate_purchased_matches(matches)
    matches.sort_by { |match| [ match[:priority], match[:evidence][:provider_span_start] ] }
      .each_with_object([]) do |match, unique|
        duplicate = unique.find do |existing|
          ranges_overlap?(
            existing[:evidence][:provider_span_start], existing[:evidence][:provider_span_end],
            match[:evidence][:provider_span_start], match[:evidence][:provider_span_end]
          ) &&
            canonical_decimal(existing[:quantity_text]) == canonical_decimal(match[:quantity_text]) &&
            normalized_unit_text(existing[:unit_text]) == normalized_unit_text(match[:unit_text])
        end
        unique << match unless duplicate
      end
  end

  def purchased_quantity_component(purchased_match)
    return [ nil, [ "missing_purchased_quantity", "missing_purchased_unit" ] ] if purchased_match.nil?

    amount = canonical_decimal(purchased_match[:quantity_text])
    return [ nil, [ "invalid_purchased_quantity" ] ] if amount.nil?

    unit_resolution = resolve_unit(purchased_match[:unit_text])
    reasons = decimal_reasons(
      amount,
      maximum: MAX_QUANTITY,
      maximum_scale: MAX_QUANTITY_SCALE,
      invalid_reason: "invalid_purchased_quantity",
      bounds_reason: "purchased_quantity_out_of_bounds",
      allow_zero: false
    )
    reasons.concat(unit_reasons(unit_resolution, role: :purchased))
    if unit_resolution.known? && !valid_unit_granularity?(amount, unit_resolution.code)
      reasons << "invalid_purchased_quantity"
    end

    component = {
      amount: amount,
      unit_code: unit_resolution.code,
      unit_status: unit_resolution.status.to_s,
      evidence: purchased_match[:evidence]
    }
    component[:unit_raw] = bounded_unknown_unit_raw(unit_resolution) if unit_resolution.unknown?

    [ component, reasons ]
  end

  def structured_quantity_without_unit_match(match_data, quantity_span:, item_index:)
    {
      quantity_text: match_data[:quantity],
      unit_text: nil,
      evidence: evidence(
        source_field_path: "documents[0].fields.Items[#{item_index}].Quantity",
        item_index: item_index,
        start_offset: provider_offset(match_data.string, span_offset(quantity_span), match_data.begin(:quantity)),
        end_offset: provider_offset(match_data.string, span_offset(quantity_span), match_data.end(:quantity))
      ),
      priority: 0
    }
  end

  def tax_inclusion(reference_match)
    expression = reference_match[:expression_text]
    local_window = reference_match[:tax_window_text].to_s
    inclusions_in_window = tax_label_matches(local_window).map { |entry| entry[:inclusion] }
    if inclusions_in_window.uniq.many?
      return [ "unknown", nil, [ "ambiguous_tax_inclusion", "ambiguous_reference_expression" ] ]
    end

    inclusion = if reference_match[:tax_text].present? && reference_match[:tax_evidence].present?
      profile.reference_price_tax_inclusion(reference_match[:tax_text])
    else
      "unknown"
    end
    matched_labels = tax_label_matches(expression).map { |entry| entry[:label] }

    if inclusion == "unknown"
      reasons = [ "ambiguous_tax_inclusion" ]
      reasons << "ambiguous_reference_expression" if matched_labels.uniq.many?
      [ "unknown", nil, reasons ]
    else
      [ inclusion, reference_match[:tax_evidence], [] ]
    end
  end

  def printed_line_total_component(value_object, item_context, item_index)
    field = value_object["TotalPrice"]
    return unless field.is_a?(Hash)

    mapped_field = bounded_structured_field(field, item_context:)
    return if mapped_field.nil?

    content = mapped_field.fetch(:content)
    span = mapped_field.fetch(:span)

    match_data = content.match(PRINTED_AMOUNT_PATTERN)
    return if match_data.nil?

    amount = canonical_decimal(match_data[:amount])
    return if amount.nil?

    {
      amount: amount,
      evidence: evidence(
        source_field_path: "documents[0].fields.Items[#{item_index}].TotalPrice",
        item_index:,
        start_offset: provider_offset(content, span_offset(span), match_data.begin(:amount)),
        end_offset: provider_offset(content, span_offset(span), match_data.end(:amount))
      )
    }
  end

  def build_corroboration(reference_price:, reference_quantity:, purchased_quantity:, printed_line_total:, reasons:)
    return if reference_price.nil? || reference_quantity.nil? || purchased_quantity.nil? || printed_line_total.nil?
    return if (reasons & (UNSUPPORTED_REASONS + [ "ambiguous_reference_expression", "ambiguous_purchased_quantity" ])).any?

    result = projection.call(
      reference_price_amount: reference_price[:amount],
      reference_quantity: reference_quantity[:amount],
      reference_unit_code: reference_quantity[:unit_code],
      purchased_quantity: purchased_quantity[:amount],
      purchased_unit_code: purchased_quantity[:unit_code]
    )
    exact_amount = result.fetch(:exact_amount).to_r
    printed_amount = Rational(printed_line_total[:amount])

    {
      exact_amount: {
        numerator: exact_amount.numerator.to_s,
        denominator: exact_amount.denominator.to_s
      },
      projected_amount: Integer(result.fetch(:projected_amount)),
      printed_line_total: printed_line_total[:amount],
      rounding_matches: rounding_matches(exact_amount, printed_amount)
    }
  rescue ReceiptAmountService::InvalidItemSourceError, ArgumentError, KeyError, TypeError
    nil
  end

  def structured_value_conflict_reasons(value_object:, reference_price:, purchased_quantity:, printed_line_total:)
    conflicts = [
      structured_numeric_field_conflict?(value_object["Price"], reference_price&.dig(:amount)),
      structured_numeric_field_conflict?(value_object["Quantity"], purchased_quantity&.dig(:amount)),
      structured_unit_field_conflict?(value_object["QuantityUnit"], purchased_quantity),
      structured_numeric_field_conflict?(value_object["TotalPrice"], printed_line_total&.dig(:amount))
    ]

    conflicts.any? ? [ "ambiguous_reference_expression" ] : []
  end

  def structured_numeric_field_conflict?(field, lexical_amount)
    return false unless field.is_a?(Hash)

    values = []
    currency = field["valueCurrency"]
    values << currency["amount"] if currency.is_a?(Hash) && currency.key?("amount")
    values << field["valueNumber"] if field.key?("valueNumber")
    return false if values.empty?
    return true if lexical_amount.nil?

    lexical_decimal = BigDecimal(lexical_amount)
    values.any? do |value|
      structured_decimal = structured_decimal_value(value)
      structured_decimal.nil? || structured_decimal != lexical_decimal
    end
  rescue ArgumentError
    true
  end

  def structured_decimal_value(value)
    case value
    when Integer
      return if value.bit_length > 256

      BigDecimal(value.to_s)
    when Float
      return unless value.finite?

      BigDecimal(value.to_s)
    when BigDecimal
      return unless value.finite?
      return if value.precision > 64 || value.exponent.abs > 64

      value
    when String
      canonical = canonical_decimal(value)
      BigDecimal(canonical) if canonical
    end
  rescue ArgumentError
    nil
  end

  def structured_unit_field_conflict?(field, purchased_quantity)
    return false unless field.is_a?(Hash) && field.key?("valueString")
    return true if purchased_quantity.nil?

    resolution = resolve_unit(field["valueString"])
    status = purchased_quantity[:unit_status].to_s

    case status
    when "known"
      !resolution.known? || resolution.code != purchased_quantity[:unit_code]
    when "blank"
      !resolution.blank?
    when "unknown"
      !resolution.unknown? || resolution.raw != purchased_quantity[:unit_raw]
    else
      true
    end
  end

  def rounding_matches(exact_amount, printed_amount)
    {
      "floor" => exact_amount.floor,
      "half_up" => (exact_amount + Rational(1, 2)).floor,
      "ceil" => exact_amount.ceil
    }.filter_map { |name, amount| name if Rational(amount) == printed_amount }
  end

  def resolve_unit(value)
    profile.resolve_quantity_unit(normalized_unit_text(value))
  end

  def normalized_unit_text(value)
    normalized_mappable_text(value, max_bytes: 64).to_s
  end

  def bounded_unknown_unit_raw(resolution)
    raw = resolution.raw.to_s
    return raw if raw.bytesize <= 64

    bounded = raw.byteslice(0, 64).to_s
    bounded = bounded.byteslice(0, bounded.bytesize - 1).to_s until bounded.valid_encoding?
    bounded
  end

  def valid_unit_granularity?(amount, unit_code)
    unit = ReceiptQuantityUnit.unit_for(unit_code)
    return false unless unit

    (Rational(amount) / unit.input_granularity).denominator == 1
  rescue ArgumentError, ZeroDivisionError
    false
  end

  def unit_reasons(resolution, role:)
    return [ role == :reference ? "missing_reference_unit" : "missing_purchased_unit" ] if resolution.blank?
    return [ role == :reference ? "unsupported_reference_unit" : "unsupported_purchased_unit" ] unless resolution.known?

    unit = ReceiptQuantityUnit.unit_for(resolution.code)
    return [] if unit&.allows_pricing_role?(role)

    [ role == :reference ? "unsupported_reference_unit" : "unsupported_purchased_unit" ]
  end

  def decimal_reasons(amount, maximum:, maximum_scale:, invalid_reason:, bounds_reason:, allow_zero:)
    decimal = BigDecimal(amount)
    return [ invalid_reason ] unless decimal.finite?
    return [ invalid_reason ] if decimal_scale(amount) > maximum_scale
    return [ bounds_reason ] if decimal.negative? || (!allow_zero && decimal.zero?)
    return [ bounds_reason ] if decimal > maximum

    []
  rescue ArgumentError
    [ invalid_reason ]
  end

  def canonical_decimal(value)
    normalized = normalized_mappable_text(value, max_bytes: 64)
    return if normalized.nil?
    return unless normalized.match?(/\A#{DECIMAL_SOURCE}\z/u)

    without_grouping = normalized.delete(",，")
    integer, fraction = without_grouping.split(".", 2)
    integer = integer.sub(/\A0+(?=\d)/, "")
    fraction = fraction&.sub(/0+\z/, "")

    fraction.present? ? "#{integer}.#{fraction}" : integer
  end

  def decimal_scale(amount)
    amount.include?(".") ? amount.split(".", 2).last.length : 0
  end

  def tax_basis_labels
    labels = profile.reference_price_tax_basis_labels
    labels.is_a?(Hash) ? labels : {}
  end

  def local_expression_line(text, start_offset, end_offset)
    line_start = previous_line_break_index(text, start_offset)
    line_end = text.index(LINE_BREAK_PATTERN, end_offset)

    text[(line_start ? line_start + 1 : 0)...(line_end || text.length)].to_s
  end

  def previous_line_break_index(text, offset)
    return if offset <= 0

    text.rindex(LINE_BREAK_PATTERN, offset - 1)
  end

  def normalized_mappable_text(value, max_bytes:)
    encoded = raw_mappable_text(value, max_bytes:)&.freeze
    return if encoded.nil?

    normalized = encoded.unicode_normalize(:nfkc).freeze
    return unless normalized.length == encoded.length
    return unless provider_length(normalized) == provider_length(encoded)

    normalized
  rescue EncodingError, ArgumentError
    nil
  end

  def raw_mappable_text(value, max_bytes:)
    return unless value.is_a?(String)
    return if value.bytesize > max_bytes
    return unless value.valid_encoding?
    return if value.match?(CONTROL_CHARACTER_PATTERN)

    value.encode(Encoding::UTF_8)
  rescue EncodingError, ArgumentError
    nil
  end

  def build_item_context(item, spans:)
    raw_content = raw_mappable_text(item["content"], max_bytes: MAX_ITEM_CONTENT_BYTES)
    content = normalized_mappable_text(item["content"], max_bytes: MAX_ITEM_CONTENT_BYTES)
    return if raw_content.nil? || content.nil? || spans.nil?
    return if spans.sum { |span| span_length(span) } > MAX_ITEM_CONTENT_BYTES

    raw_segments = owned_raw_segments(raw_content, spans)
    return if raw_segments.nil? || raw_segments.join("\n") != raw_content

    segments = spans.zip(raw_segments).filter_map do |span, raw_segment|
      normalized_segment = normalized_mappable_text(raw_segment, max_bytes: MAX_ITEM_CONTENT_BYTES)
      next if normalized_segment.nil?

      { span:, content: normalized_segment.freeze }.freeze
    end
    return unless segments.size == spans.size
    return unless segments.map { |segment| segment.fetch(:content) }.join("\n") == content

    {
      spans: spans.freeze,
      segments: segments.freeze
    }.freeze
  end

  def owned_raw_segments(raw_content, spans)
    if provider_content_supplied
      segments = spans.map do |span|
        mapper.slice(
          provider_content,
          offset: span_offset(span),
          length: span_length(span)
        )
      end
      return if segments.any?(&:nil?)

      segments
    elsif spans.one?
      return unless provider_length(raw_content) <= span_length(spans.sole)

      [ raw_content ]
    else
      segments = raw_content.split("\n", -1)
      return unless segments.size == spans.size
      return unless segments.zip(spans).all? do |segment, span|
        provider_length(segment) == span_length(span)
      end

      segments
    end
  rescue EncodingError, ArgumentError
    nil
  end

  def bounded_parent_spans(item)
    spans = item["spans"]
    return unless spans.is_a?(Array) && spans.size.between?(1, MAX_COMPONENT_SPANS)

    normalized = spans.map { |span| bounded_span(span) }
    return if normalized.any?(&:nil?)
    return unless ordered_positive_nonoverlapping_spans?(normalized)

    normalized
  end

  def ordered_positive_nonoverlapping_spans?(spans)
    return false unless spans.all? { |span| span_length(span).positive? }

    spans.each_cons(2).all? do |left, right|
      span_offset(left) < span_offset(right) && span_end(left) <= span_offset(right)
    end
  end

  def segment_containing_range(item_context, start_offset, end_offset)
    return unless start_offset.is_a?(Integer) && end_offset.is_a?(Integer)
    return if end_offset < start_offset

    item_context.fetch(:segments).find do |segment|
      span = segment.fetch(:span)
      start_offset >= span_offset(span) && end_offset <= span_end(span)
    end
  end

  def exact_top_level_content?(raw_content, span)
    return false if raw_content.nil?
    return true unless provider_content_supplied

    mapper.slice(
      provider_content,
      offset: span_offset(span),
      length: span_length(span)
    ) == raw_content
  end

  def content_supplied?(value)
    return false if value.nil?
    return true unless value.is_a?(String)
    return true if value.bytesize > MAX_FIELD_CONTENT_BYTES
    return true unless value.valid_encoding?

    value.present?
  rescue EncodingError, ArgumentError
    true
  end

  def single_span(container)
    spans = container["spans"]
    return unless spans.is_a?(Array) && spans.size == 1

    bounded_span(spans.first)
  end

  def bounded_span(span)
    return unless span.is_a?(Hash)
    return unless span["offset"].is_a?(Integer) && span["length"].is_a?(Integer)
    return if span["offset"].negative? || span["length"].negative?
    return if span["offset"] > MAX_PROVIDER_SPAN_VALUE || span["length"] > MAX_PROVIDER_SPAN_VALUE
    return if span["offset"] + span["length"] > MAX_PROVIDER_SPAN_VALUE

    span
  end

  def mark_item_identity_conflicts(candidates, parent_span_sets)
    overlap_index = build_parent_span_overlap_index(parent_span_sets)
    conflicting_indexes = candidates.each_with_object({}) do |candidate, indexes|
      item_index = candidate[:item_index]
      next unless parent_span_sets[item_index]

      conflict = candidate_evidence_ranges(candidate).any? do |start_offset, end_offset|
        parent_span_overlap_with_other_item?(
          overlap_index,
          start_offset: start_offset,
          end_offset: end_offset,
          item_index: item_index
        )
      end

      indexes[item_index] = true if conflict
    end

    candidates.map do |candidate|
      next candidate unless conflicting_indexes.key?(candidate[:item_index])

      reasons = normalize_reasons(candidate[:rejection_reasons] + [ "ambiguous_reference_expression" ])
      candidate.merge(
        validation_state: validation_state(reasons),
        rejection_reasons: reasons,
        corroboration: nil
      )
    end
  end

  def build_parent_span_overlap_index(parent_span_sets)
    entries = parent_span_sets.each_with_index.flat_map do |spans, item_index|
      next [] unless spans

      spans.map do |span|
        {
          start_offset: span_offset(span),
          end_offset: span_end(span),
          item_index: item_index
        }
      end
    end.sort_by { |entry| [ entry[:start_offset], entry[:end_offset], entry[:item_index] ] }

    starts = []
    prefix_top_two = []
    top_two = []
    entries.each do |entry|
      starts << entry[:start_offset]
      top_two = (top_two + [ entry ])
        .sort_by { |candidate| [ -candidate[:end_offset], candidate[:item_index] ] }
        .first(2)
      prefix_top_two << top_two
    end

    { starts: starts, prefix_top_two: prefix_top_two }
  end

  def parent_span_overlap_with_other_item?(overlap_index, start_offset:, end_offset:, item_index:)
    prefix_length = lower_bound(overlap_index[:starts], end_offset)
    return false if prefix_length.zero?

    overlap_index[:prefix_top_two].fetch(prefix_length - 1).any? do |entry|
      entry[:item_index] != item_index && entry[:end_offset] > start_offset
    end
  end

  def lower_bound(sorted_values, target)
    left = 0
    right = sorted_values.length

    while left < right
      middle = (left + right) / 2
      if sorted_values[middle] < target
        left = middle + 1
      else
        right = middle
      end
    end

    left
  end

  def candidate_evidence_ranges(candidate)
    [
      candidate.dig(:reference_price, :evidence),
      candidate.dig(:reference_quantity, :evidence),
      candidate.dig(:purchased_quantity, :evidence),
      candidate[:tax_inclusion_evidence],
      candidate.dig(:printed_line_total, :evidence)
    ].compact.map do |component_evidence|
      [ component_evidence[:provider_span_start], component_evidence[:provider_span_end] ]
    end
  end

  def span_offset(span)
    span["offset"]
  end

  def span_length(span)
    span["length"]
  end

  def span_end(span)
    span_offset(span) + span_length(span)
  end

  def span_within?(inner, outer)
    range_within_parent?(span_offset(inner), span_end(inner), outer)
  end

  def range_within_parent?(start_offset, end_offset, parent)
    return false unless end_offset >= start_offset

    if parent.is_a?(Hash) && parent.key?(:segments)
      segment_containing_range(parent, start_offset, end_offset).present?
    else
      start_offset >= span_offset(parent) && end_offset <= span_end(parent)
    end
  end

  def ranges_overlap?(left_start, left_end, right_start, right_end)
    left_start < right_end && right_start < left_end
  end

  def evidence(source_field_path:, item_index:, start_offset:, end_offset:)
    {
      source_provider: "azure_structured",
      source_field_path: source_field_path,
      item_index: item_index,
      provider_span_start: start_offset,
      provider_span_end: end_offset
    }
  end

  def provider_offset(text, base_offset, character_index)
    byte_offset = text[0...character_index].to_s.bytesize
    span = mapper.span_for_bytes(text, byte_offset:, byte_length: 0)
    return if span.nil?

    base_offset + span.fetch(:offset)
  end

  def provider_length(text)
    mapper.length(text)
  end

  def normalize_reasons(reasons)
    order = REJECTION_REASONS.each_with_index.to_h
    reasons.compact.uniq.select { |reason| order.key?(reason) }
      .sort_by { |reason| order.fetch(reason) }
      .first(MAX_REJECTION_REASONS)
  end

  def validation_state(reasons)
    return "unsupported" if (reasons & UNSUPPORTED_REASONS).any?
    return "ambiguous" if (reasons & AMBIGUOUS_REASONS).any?
    return "missing" if (reasons & MISSING_REASONS).any?

    "valid"
  end
end
