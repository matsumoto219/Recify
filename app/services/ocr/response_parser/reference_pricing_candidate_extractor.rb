class Ocr::ResponseParser::ReferencePricingCandidateExtractor
  MAX_ITEMS = 100
  MAX_ITEM_CONTENT_BYTES = 4_096
  MAX_FIELD_CONTENT_BYTES = 512
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
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.freeze

  def self.call(items:, profile:, projection: nil)
    new(items:, profile:, projection:).call
  end

  def initialize(items:, profile:, projection: nil)
    @items = items
    @profile = profile
    @projection = projection || ->(**attributes) {
      ReceiptAmountService.reference_item_extension_projection(**attributes)
    }
  end

  def call
    return [] unless items.is_a?(Array)

    bounded_items = items.first(MAX_ITEMS)
    parent_spans = bounded_items.map { |item| item.is_a?(Hash) ? single_span(item) : nil }
    candidates = bounded_items.filter_map.with_index do |item, item_index|
      extract_candidate(item, item_index)
    rescue EncodingError, TypeError, ArgumentError
      nil
    end

    mark_item_identity_conflicts(candidates, parent_spans)
  end

  private

  attr_reader :items, :profile, :projection

  def extract_candidate(item, item_index)
    return unless item.is_a?(Hash)

    item_content = normalized_mappable_text(item["content"], max_bytes: MAX_ITEM_CONTENT_BYTES)
    parent_span = single_span(item)
    return if item_content.nil? || parent_span.nil?
    return unless utf16_length(item_content) <= span_length(parent_span)

    value_object = item["valueObject"]
    value_object = {} unless value_object.is_a?(Hash)
    reference_matches, evidence_errors = reference_matches(
      item,
      value_object,
      item_content,
      parent_span,
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
      item_content,
      parent_span,
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

    printed_line_total = printed_line_total_component(value_object, parent_span, item_index)
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

  def reference_matches(item, value_object, item_content, parent_span, item_index)
    matches = []
    evidence_errors = []
    price_field = value_object["Price"]

    if price_field.is_a?(Hash) && price_field["content"].present?
      field_content = normalized_mappable_text(price_field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES)
      field_span = single_span(price_field)

      if field_content.nil? || field_span.nil? || !span_within?(field_span, parent_span) ||
          utf16_length(field_content) > span_length(field_span)
        evidence_errors << "evidence_outside_item"
      else
        matches.concat(scan_reference_expressions(
          field_content,
          base_offset: span_offset(field_span),
          source_field_path: "documents[0].fields.Items[#{item_index}].Price",
          item_index: item_index,
          parent_span: parent_span,
          priority: 0
        ))
      end
    end

    matches.concat(scan_reference_expressions(
      item_content,
      base_offset: span_offset(parent_span),
      source_field_path: "documents[0].fields.Items[#{item_index}]",
      item_index: item_index,
      parent_span: parent_span,
      priority: 1
    ))

    if matches.empty?
      incomplete = scan_incomplete_reference_expression(
        price_field,
        item_content: item_content,
        parent_span: parent_span,
        item_index: item_index
      )
      matches << incomplete if incomplete
    end

    [ deduplicate_reference_matches(matches), evidence_errors ]
  end

  def scan_incomplete_reference_expression(price_field, item_content:, parent_span:, item_index:)
    field_content = price_field.is_a?(Hash) ?
      normalized_mappable_text(price_field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES) : nil
    field_span = price_field.is_a?(Hash) ? single_span(price_field) : nil
    if field_content.present? && field_span && span_within?(field_span, parent_span)
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

    match_data = item_content.match(INCOMPLETE_REFERENCE_PATTERN)
    return unless match_data

    build_incomplete_reference_match(
      match_data,
      item_content,
      base_offset: span_offset(parent_span),
      source_field_path: "documents[0].fields.Items[#{item_index}]",
      item_index: item_index,
      priority: 1
    )
  end

  def build_incomplete_reference_match(match_data, text, base_offset:, source_field_path:, item_index:, priority:)
    price_capture = match_data[:price_prefix].present? ? :price_prefix : :price_suffix
    reference_start = match_data.begin(:reference_quantity)
    local_window = local_expression_line(text, match_data.begin(0), match_data.end(0))
    matched_tax = tax_basis_labels.values.flatten.find { |label| local_window.include?(label) }
    tax_local_start = matched_tax ? local_window.index(matched_tax) : nil
    line_start = text.rindex("\n", match_data.begin(0) - 1)
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

  def scan_reference_expressions(text, base_offset:, source_field_path:, item_index:, parent_span:, priority:)
    text.to_enum(:scan, reference_expression_pattern).filter_map do
      match_data = Regexp.last_match
      match = build_reference_match(
        match_data,
        text,
        base_offset:,
        source_field_path:,
        item_index:,
        priority:
      )

      match if range_within_parent?(match[:expression_start], match[:expression_end], parent_span)
    end
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
      tax_text: tax_capture ? match_data[tax_capture] : nil,
      tax_evidence: tax_capture ? evidence(
        source_field_path:,
        item_index:,
        start_offset: provider_offset(text, base_offset, match_data.begin(tax_capture)),
        end_offset: provider_offset(text, base_offset, match_data.end(tax_capture))
      ) : nil,
      tax_window_text: local_expression_line(text, match_data.begin(0), match_data.end(0)),
      priority: priority,
      source_text: text
    }
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

  def purchased_quantity_matches(value_object, item_content, parent_span, item_index, reference_match)
    matches = []
    evidence_errors = []
    quantity_field = value_object["Quantity"]

    if quantity_field.is_a?(Hash) && quantity_field["content"].present?
      quantity_content = normalized_mappable_text(quantity_field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES)
      quantity_span = single_span(quantity_field)

      if quantity_content.nil? || quantity_span.nil? || !span_within?(quantity_span, parent_span) ||
          utf16_length(quantity_content) > span_length(quantity_span)
        evidence_errors << "evidence_outside_item"
      else
        structured_matches = scan_purchased_quantities(
          quantity_content,
          base_offset: span_offset(quantity_span),
          source_field_path: "documents[0].fields.Items[#{item_index}].Quantity",
          item_index:,
          parent_span:,
          reference_end: reference_match[:expression_end],
          enforce_after_reference: false,
          priority: 0
        )
        if structured_matches.empty?
          numeric_only = quantity_content.match(/\A[ \t]*(?<quantity>#{DECIMAL_SOURCE})[ \t]*\z/u)
          matches << structured_quantity_without_unit_match(
            numeric_only,
            quantity_span: quantity_span,
            item_index: item_index
          ) if numeric_only
        else
          matches.concat(structured_matches)
        end
      end
    end

    matches.concat(scan_purchased_quantities(
      item_content,
      base_offset: span_offset(parent_span),
      source_field_path: nil,
      item_index:,
      parent_span:,
      reference_end: reference_match[:expression_end],
      enforce_after_reference: true,
      priority: 1,
      value_object: value_object
    ))

    [ deduplicate_purchased_matches(matches), evidence_errors ]
  end

  def scan_purchased_quantities(
    text,
    base_offset:,
    source_field_path:,
    item_index:,
    parent_span:,
    reference_end:,
    enforce_after_reference:,
    priority:,
    value_object: nil
  )
    text.to_enum(:scan, PURCHASED_QUANTITY_PATTERN).filter_map do
      match_data = Regexp.last_match
      global_start = provider_offset(text, base_offset, match_data.begin(:quantity))
      global_end = provider_offset(text, base_offset, match_data.end(:unit))
      next if enforce_after_reference && global_start < reference_end
      next unless range_within_parent?(global_start, global_end, parent_span)
      next if package_quantity_context?(text, match_data)

      path = source_field_path || component_field_path_for_range(
        value_object,
        global_start,
        global_end,
        item_index
      )
      next if path.end_with?(".Description") && !quantity_only_component_span?(
        value_object["Description"],
        global_start,
        global_end
      )
      next if enforce_after_reference &&
        path == "documents[0].fields.Items[#{item_index}]" &&
        newline_between_provider_offsets?(text, base_offset, reference_end, global_start)

      {
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
  end

  def package_quantity_context?(text, match_data)
    before = text[[ match_data.begin(0) - 12, 0 ].max...match_data.begin(0)].to_s
    after = text[match_data.end(0), 6].to_s

    before.match?(/(?:約|およそ|[x×@＠]|[-–—〜～~]|gross|tare|風袋|総重量)\s*\z/i) ||
      after.match?(/\A\s*(?:入|入り|詰|パック|[x×@＠]|gross|tare|風袋|総重量)/i)
  end

  def quantity_only_component_span?(field, start_offset, end_offset)
    return false unless field.is_a?(Hash)

    spans = field["spans"]
    return false unless spans.is_a?(Array) && spans.many?

    spans.drop(1).any? do |span|
      normalized_span = bounded_span(span)
      normalized_span && span_offset(normalized_span) == start_offset && span_end(normalized_span) >= end_offset
    end
  end

  def component_field_path_for_range(value_object, start_offset, end_offset, item_index)
    %w[Quantity Description QuantityUnit].each do |field_name|
      field = value_object[field_name]
      next unless field.is_a?(Hash)

      spans = field["spans"]
      next unless spans.is_a?(Array)
      next unless spans.any? { |span| range_within_parent?(start_offset, end_offset, span) }

      return "documents[0].fields.Items[#{item_index}].#{field_name}"
    end

    "documents[0].fields.Items[#{item_index}]"
  end

  def newline_between_provider_offsets?(text, base_offset, start_offset, end_offset)
    text.each_char.with_index.any? do |character, character_index|
      next false unless character == "\n"

      newline_offset = provider_offset(text, base_offset, character_index)
      newline_offset >= start_offset && newline_offset < end_offset
    end
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
    inclusions_in_window = tax_basis_labels.filter_map do |inclusion, labels|
      inclusion if labels.any? { |label| local_window.include?(label) }
    end
    if inclusions_in_window.uniq.many?
      return [ "unknown", nil, [ "ambiguous_tax_inclusion", "ambiguous_reference_expression" ] ]
    end

    inclusion = profile.reference_price_tax_inclusion(reference_match[:tax_text].presence || expression)
    matched_labels = tax_basis_labels.values.flatten.select { |label| expression.include?(label) }

    if inclusion == "unknown"
      reasons = [ "ambiguous_tax_inclusion" ]
      reasons << "ambiguous_reference_expression" if matched_labels.uniq.many?
      [ "unknown", nil, reasons ]
    else
      [ inclusion, reference_match[:tax_evidence], [] ]
    end
  end

  def printed_line_total_component(value_object, parent_span, item_index)
    field = value_object["TotalPrice"]
    return unless field.is_a?(Hash)

    content = normalized_mappable_text(field["content"], max_bytes: MAX_FIELD_CONTENT_BYTES)
    span = single_span(field)
    return if content.nil? || span.nil? || !span_within?(span, parent_span) ||
      utf16_length(content) > span_length(span)

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
      return if value.precs.first > 64 || value.exponent.abs > 64

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
    line_start = text.rindex("\n", start_offset - 1)
    line_end = text.index("\n", end_offset)

    text[(line_start ? line_start + 1 : 0)...(line_end || text.length)].to_s
  end

  def normalized_mappable_text(value, max_bytes:)
    return unless value.is_a?(String)
    return unless value.valid_encoding?
    return if value.bytesize > max_bytes || value.match?(CONTROL_CHARACTER_PATTERN)

    encoded = value.encode(Encoding::UTF_8)
    normalized = encoded.unicode_normalize(:nfkc)
    return unless normalized.length == encoded.length
    return unless utf16_length(normalized) == utf16_length(encoded)

    normalized
  rescue EncodingError, ArgumentError
    nil
  end

  def single_span(container)
    spans = container["spans"]
    return unless spans.is_a?(Array) && spans.one?

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

  def mark_item_identity_conflicts(candidates, parent_spans)
    conflicting_indexes = candidates.each_with_object([]) do |candidate, indexes|
      item_index = candidate[:item_index]
      parent_span = parent_spans[item_index]
      next unless parent_span

      evidence_ranges = candidate_evidence_ranges(candidate)
      conflict = parent_spans.each_with_index.any? do |other_span, other_index|
        next false if other_index == item_index || other_span.nil?

        same_span = span_offset(parent_span) == span_offset(other_span) && span_end(parent_span) == span_end(other_span)
        same_span || evidence_ranges.any? do |start_offset, end_offset|
          ranges_overlap?(start_offset, end_offset, span_offset(other_span), span_end(other_span))
        end
      end
      indexes << item_index if conflict
    end

    candidates.map do |candidate|
      next candidate unless conflicting_indexes.include?(candidate[:item_index])

      reasons = normalize_reasons(candidate[:rejection_reasons] + [ "ambiguous_reference_expression" ])
      candidate.merge(
        validation_state: validation_state(reasons),
        rejection_reasons: reasons,
        corroboration: nil
      )
    end
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

  def range_within_parent?(start_offset, end_offset, parent_span)
    start_offset >= span_offset(parent_span) &&
      end_offset >= start_offset &&
      end_offset <= span_end(parent_span)
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
    base_offset + utf16_length(text[0...character_index].to_s)
  end

  def utf16_length(text)
    text.encode(Encoding::UTF_16LE).bytesize / 2
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
