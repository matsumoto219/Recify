class Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor
  MAX_ITEMS = 20
  MAX_TAX_DETAILS = 20
  MAX_PARENT_SPANS = Ocr::ResponseParser::MAX_REFERENCE_PRICING_AUTHORITY_SPANS
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES
  MAX_LINE_CONTENT_BYTES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
  MAX_PARENT_CONTENT_BYTES = 4_096
  MAX_PATH_BYTES = 256
  MAX_PAGE_DIMENSION = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PAGE_DIMENSION
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  FIELD_LINE_BOUNDS_TOLERANCE = 2
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  EVIDENCE_KIND = "structured_items_receipt_inner_tax_summary"
  SOURCE_PROVIDER = "azure_structured"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\r\n\u0085\u2028\u2029]/.freeze
  JPY_AMOUNT_PATTERN = /\A\s*[¥￥]?\s*(?<amount>(?:\d{1,3}(?:,\d{3})+|\d+))\s*(?:円)?\s*\z/.freeze

  Result = Data.define(
    :kind,
    :string_index_type,
    :item_parents,
    :item_totals,
    :tax_detail_parents,
    :tax_descriptions,
    :tax_amounts,
    :summary_total
  ) do
    def initialize(
      string_index_type:,
      item_parents:,
      item_totals:,
      tax_detail_parents:,
      tax_descriptions:,
      tax_amounts:,
      summary_total:
    )
      super(
        kind: EVIDENCE_KIND.dup.freeze,
        string_index_type: string_index_type.dup.freeze,
        item_parents: item_parents.map { |entry| entry.deep_dup.freeze }.freeze,
        item_totals: item_totals.map { |entry| entry.deep_dup.freeze }.freeze,
        tax_detail_parents: tax_detail_parents.map { |entry| entry.deep_dup.freeze }.freeze,
        tax_descriptions: tax_descriptions.map { |entry| entry.deep_dup.freeze }.freeze,
        tax_amounts: tax_amounts.map { |entry| entry.deep_dup.freeze }.freeze,
        summary_total: summary_total.deep_dup.freeze
      )
    end
  end

  def self.call(analyze_result:, profile:, receipt_total:)
    new(analyze_result:, profile:, receipt_total:).call
  end

  def initialize(analyze_result:, profile:, receipt_total:)
    @analyze_result = analyze_result
    @profile = profile
    @receipt_total = receipt_total
  end

  def call
    return unless provider_context_valid?

    fields = exact_document_fields
    return if fields.nil?

    item_entries = exact_item_entries(fields)
    tax_entries = exact_tax_entries(fields)
    summary_total = exact_summary_total(fields)
    return if item_entries.nil? || tax_entries.nil? || summary_total.nil?
    return unless exact_whole_amount(receipt_total) == summary_total.fetch(:amount)
    return unless item_entries.sum { |entry| entry.fetch(:total).fetch(:amount) } == summary_total.fetch(:amount)
    return unless aggregate_ranges_disjoint?(item_entries:, tax_entries:, summary_total:)

    Result.new(
      string_index_type: mapper.index_type,
      item_parents: item_entries.map { |entry| entry.fetch(:parent) },
      item_totals: item_entries.map { |entry| entry.fetch(:total) },
      tax_detail_parents: tax_entries.map { |entry| entry.fetch(:parent) },
      tax_descriptions: tax_entries.map { |entry| entry.fetch(:description) },
      tax_amounts: tax_entries.filter_map { |entry| entry[:amount] },
      summary_total:
    )
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  private

  attr_reader :analyze_result, :content, :lines, :mapper, :page_dimensions, :profile,
    :receipt_total

  def provider_context_valid?
    return false unless analyze_result.is_a?(Hash)
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return false unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    return false if mapper.nil?

    @content = bounded_content(
      analyze_result["content"],
      maximum_bytes: Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES,
      allow_line_breaks: true
    )
    return false if content.nil?

    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.one?

    @page_dimensions = {}
    @lines = validated_page_lines(pages.sole, page_index: 0)
    lines.present?
  end

  def exact_document_fields
    documents = analyze_result["documents"]
    return unless documents.is_a?(Array) && documents.one? && documents.sole.is_a?(Hash)

    fields = documents.sole["fields"]
    fields if fields.is_a?(Hash)
  end

  def exact_item_entries(fields)
    entries = fields.dig("Items", "valueArray")
    return unless entries.is_a?(Array) && entries.size.between?(2, MAX_ITEMS)

    results = entries.map.with_index do |entry, item_index|
      exact_item_entry(entry, item_index:)
    end
    return if results.any?(&:nil?)

    results.freeze
  end

  def exact_item_entry(entry, item_index:)
    path = "documents[0].fields.Items[#{item_index}]"
    parent = exact_parent(entry, source_field_path: path, index_key: :item_index, index: item_index)
    return if parent.nil?

    total = exact_money_child(
      entry.dig("valueObject", "TotalPrice"),
      parent:,
      source_field_path: "#{path}.TotalPrice",
      index_key: :item_index,
      index: item_index,
      positive: false
    )
    return if total.nil?

    { parent: parent.fetch(:evidence), total: }.freeze
  end

  def exact_tax_entries(fields)
    entries = fields.dig("TaxDetails", "valueArray")
    return unless entries.is_a?(Array) && entries.size.between?(1, MAX_TAX_DETAILS)

    results = entries.map.with_index do |entry, tax_detail_index|
      exact_tax_entry(entry, tax_detail_index:)
    end
    return if results.any?(&:nil?)

    results.freeze
  end

  def exact_tax_entry(entry, tax_detail_index:)
    path = "documents[0].fields.TaxDetails[#{tax_detail_index}]"
    parent = exact_parent(
      entry,
      source_field_path: path,
      index_key: :tax_detail_index,
      index: tax_detail_index
    )
    return if parent.nil?

    description = exact_tax_description(
      entry.dig("valueObject", "Description"),
      parent:,
      source_field_path: "#{path}.Description",
      tax_detail_index:
    )
    amount_field = entry.dig("valueObject", "Amount")
    amount = if amount_field.nil?
      nil
    else
      exact_money_child(
        amount_field,
        parent:,
        source_field_path: "#{path}.Amount",
        index_key: :tax_detail_index,
        index: tax_detail_index,
        positive: false,
        allow_trailing_closing_parenthesis: parent.fetch(:enclosed_by_parentheses)
      )
    end
    return if description.nil? || (amount_field && amount.nil?)
    return if amount && ranges_overlap?(span_range(description), span_range(amount))

    { parent: parent.fetch(:evidence), description:, amount: }.freeze
  end

  def exact_parent(entry, source_field_path:, index_key:, index:)
    return unless entry.is_a?(Hash)
    return if source_field_path.bytesize > MAX_PATH_BYTES

    parent_content = bounded_content(
      entry["content"],
      maximum_bytes: MAX_PARENT_CONTENT_BYTES,
      allow_line_breaks: true
    )
    spans = exact_provider_spans(entry["spans"])
    bounds = exact_field_region_bounds(entry)
    return if parent_content.nil? || spans.nil? || bounds.nil?
    return unless exact_provider_segments?(parent_content, spans)

    evidence = {
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.dup.freeze,
      index_key => index,
      provider_spans: spans.map do |span|
        {
          provider_span_start: span.begin,
          provider_span_end: span.end
        }.freeze
      end.freeze
    }.freeze
    {
      evidence:,
      spans:,
      bounds:,
      enclosed_by_parentheses: enclosed_by_parentheses?(parent_content)
    }.freeze
  end

  def exact_tax_description(field, parent:, source_field_path:, tax_detail_index:)
    return unless field.is_a?(Hash)
    return unless profile.respond_to?(:ocr_reference_pricing_single_structured_item_inner_tax_description_pattern)

    field_content = bounded_content(
      field["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    value_string = bounded_content(
      field["valueString"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_single_span(field["spans"])
    return if field_content.nil? || value_string.nil? || span.nil?
    return unless field_content == value_string && exact_provider_content?(field_content, span)
    return unless field_content.unicode_normalize(:nfkc).strip.match?(
      profile.ocr_reference_pricing_single_structured_item_inner_tax_description_pattern
    )

    child_evidence(
      field,
      span:,
      parent:,
      source_field_path:,
      index_key: :tax_detail_index,
      index: tax_detail_index
    )
  end

  def exact_money_child(
    field,
    parent:,
    source_field_path:,
    index_key:,
    index:,
    positive:,
    allow_trailing_closing_parenthesis: false
  )
    return unless field.is_a?(Hash)

    field_content = bounded_content(
      field["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_single_span(field["spans"])
    return if field_content.nil? || span.nil?
    return unless exact_provider_content?(field_content, span)

    amount = exact_jpy_lexeme(
      field_content,
      allow_trailing_closing_parenthesis: allow_trailing_closing_parenthesis &&
        span.end == parent.fetch(:spans).last.end
    )
    return if amount.nil? || exact_structured_currency_amount(field) != amount
    return if positive ? !amount.positive? : amount.negative?

    evidence = child_evidence(
      field,
      span:,
      parent:,
      source_field_path:,
      index_key:,
      index:
    )
    evidence&.merge(amount:)&.freeze
  end

  def child_evidence(field, span:, parent:, source_field_path:, index_key:, index:)
    return if source_field_path.bytesize > MAX_PATH_BYTES
    return unless parent.fetch(:spans).one? { |parent_span| range_within?(span, parent_span) }

    regions = exact_field_region_bounds(field)
    return if regions.nil?

    owners = lines.select { |line| range_within?(span, line.fetch(:provider_span)) }
    return unless owners.one?

    owner = owners.sole
    child_bounds = regions[owner.fetch(:page_index)]
    parent_bounds = parent.fetch(:bounds)[owner.fetch(:page_index)]
    return unless bounds_within?(child_bounds, parent_bounds)

    {
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.dup.freeze,
      index_key => index,
      page_index: owner.fetch(:page_index),
      line_index: owner.fetch(:line_index),
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: span.begin,
      provider_span_end: span.end
    }.freeze
  end

  def exact_summary_total(fields)
    result = Ocr::ResponseParser::ReferencePricingStrictSummaryTotalExtractor.call(
      analyze_result:,
      profile:,
      total_field: fields["Total"]
    )
    return if result.nil? || result.document_total_evidence.nil?

    result.document_total_evidence.deep_dup.merge(amount: result.amount).freeze
  end

  def aggregate_ranges_disjoint?(item_entries:, tax_entries:, summary_total:)
    item_parent_spans = item_entries.map do |entry|
      entry.fetch(:parent).fetch(:provider_spans).map { |span| span_range(span) }
    end
    tax_parent_spans = tax_entries.map do |entry|
      entry.fetch(:parent).fetch(:provider_spans).map { |span| span_range(span) }
    end
    return false unless parent_groups_disjoint?(item_parent_spans + tax_parent_spans)

    summary_range = span_range(summary_total)
    (item_parent_spans + tax_parent_spans).flatten.none? do |range|
      ranges_overlap?(range, summary_range)
    end
  end

  def parent_groups_disjoint?(groups)
    entries = groups.flat_map.with_index do |ranges, group_index|
      ranges.map { |range| [ range, group_index ] }
    end.sort_by { |range, _group_index| [ range.begin, range.end ] }
    entries.each_cons(2).none? do |(left, left_group), (right, right_group)|
      left_group != right_group && ranges_overlap?(left, right)
    end
  end

  def validated_page_lines(page, page_index:)
    return unless page.is_a?(Hash)
    return unless page["pageNumber"] == page_index + 1 && page["unit"] == "pixel"

    width = finite_positive_dimension(page["width"])
    height = finite_positive_dimension(page["height"])
    return if width.nil? || height.nil?

    @page_dimensions[page_index] = { width:, height: }.freeze
    entries = page["lines"]
    return unless entries.is_a?(Array) && entries.size.between?(1, MAX_LINES)

    validated = entries.map.with_index do |entry, line_index|
      validated_line(entry, page_index:, line_index:)
    end
    return if validated.any?(&:nil?)
    return unless validated.each_cons(2).all? do |left, right|
      left.fetch(:provider_span).end <= right.fetch(:provider_span).begin
    end

    validated.freeze
  end

  def validated_line(entry, page_index:, line_index:)
    return unless entry.is_a?(Hash)

    line_content = bounded_content(
      entry["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_single_span(entry["spans"])
    bounds = polygon_bounds(entry["polygon"], page_index:)
    return if line_content.nil? || span.nil? || bounds.nil?
    return unless exact_provider_content?(line_content, span)

    {
      page_index:,
      line_index:,
      provider_span: span,
      bounds:
    }.freeze
  end

  def exact_provider_spans(value)
    return unless value.is_a?(Array) && value.size.between?(1, MAX_PARENT_SPANS)

    spans = value.map do |entry|
      return unless entry.is_a?(Hash)

      offset = entry["offset"]
      length = entry["length"]
      return unless offset.is_a?(Integer) && length.is_a?(Integer)
      return if offset.negative? || length <= 0
      return if offset > MAX_PROVIDER_SPAN || length > MAX_PROVIDER_SPAN - offset
      return if offset + length > mapper.length(content)

      offset...(offset + length)
    end
    return unless spans.each_cons(2).all? { |left, right| left.end <= right.begin }

    spans.freeze
  end

  def exact_single_span(value)
    spans = exact_provider_spans(value)
    spans.sole if spans&.one?
  end

  def exact_provider_content?(value, span)
    mapper.length(value) == span.size &&
      mapper.slice(content, offset: span.begin, length: span.size) == value
  end

  def exact_provider_segments?(value, spans)
    return false unless spans.sum(&:size) + spans.size - 1 == mapper.length(value)

    segments = spans.map do |span|
      segment = mapper.slice(content, offset: span.begin, length: span.size)
      return false if segment.nil?

      segment
    end
    segments.join("\n") == value
  end

  def exact_field_region_bounds(entry)
    regions = entry["boundingRegions"]
    return unless regions.is_a?(Array) && regions.one? && regions.sole.is_a?(Hash)
    return unless regions.sole["pageNumber"] == 1

    bounds = polygon_bounds(regions.sole["polygon"], page_index: 0)
    { 0 => bounds }.freeze if bounds
  end

  def polygon_bounds(polygon, page_index:)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |value| value.is_a?(Numeric) && value.finite? }

    dimensions = page_dimensions[page_index]
    return if dimensions.nil?

    xs = polygon.each_slice(2).map(&:first)
    ys = polygon.each_slice(2).map(&:last)
    return unless xs.all? { |value| value.between?(0, dimensions.fetch(:width)) }
    return unless ys.all? { |value| value.between?(0, dimensions.fetch(:height)) }

    bounds = { left: xs.min, top: ys.min, right: xs.max, bottom: ys.max }
    bounds.freeze if bounds[:right] > bounds[:left] && bounds[:bottom] > bounds[:top]
  end

  def bounds_within?(inner, outer)
    return false if inner.nil? || outer.nil?

    inner.fetch(:left) >= outer.fetch(:left) - FIELD_LINE_BOUNDS_TOLERANCE &&
      inner.fetch(:top) >= outer.fetch(:top) - FIELD_LINE_BOUNDS_TOLERANCE &&
      inner.fetch(:right) <= outer.fetch(:right) + FIELD_LINE_BOUNDS_TOLERANCE &&
      inner.fetch(:bottom) <= outer.fetch(:bottom) + FIELD_LINE_BOUNDS_TOLERANCE
  end

  def enclosed_by_parentheses?(value)
    normalized = value.unicode_normalize(:nfkc).strip
    return false unless normalized.start_with?("(") && normalized.end_with?(")")

    depth = 0
    normalized.each_char do |character|
      depth += 1 if character == "("
      depth -= 1 if character == ")"
      return false if depth.negative?
    end
    depth.zero?
  end

  def exact_jpy_lexeme(value, allow_trailing_closing_parenthesis: false)
    normalized = value.unicode_normalize(:nfkc)
    if allow_trailing_closing_parenthesis
      return unless normalized.rstrip.end_with?(")")

      normalized = normalized.rstrip.delete_suffix(")").rstrip
    end
    match = JPY_AMOUNT_PATTERN.match(normalized)
    return if match.nil?

    amount = Integer(match[:amount].delete(","), exception: false)
    amount if amount&.between?(0, MAX_AMOUNT)
  end

  def exact_structured_currency_amount(field)
    currency = field["valueCurrency"]
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

    value = currency["amount"]
    return unless value.is_a?(Numeric) && value.finite?

    decimal = BigDecimal(value.to_s)
    decimal.to_i if decimal.frac.zero? && decimal.between?(0, MAX_AMOUNT)
  rescue ArgumentError
    nil
  end

  def exact_whole_amount(value)
    return unless value.is_a?(Numeric) && value.finite?

    decimal = BigDecimal(value.to_s)
    decimal.to_i if decimal.frac.zero? && decimal.between?(0, MAX_AMOUNT)
  rescue ArgumentError
    nil
  end

  def finite_positive_dimension(value)
    return unless value.is_a?(Numeric) && value.finite? && value.positive?
    return if value > MAX_PAGE_DIMENSION

    value
  end

  def bounded_content(value, maximum_bytes:, allow_line_breaks:)
    return unless value.is_a?(String) && value.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding)
    return if value.blank? || value.bytesize > maximum_bytes
    return if value.match?(CONTROL_CHARACTER_PATTERN)
    return if !allow_line_breaks && value.match?(LINE_BREAK_PATTERN)
    return if mapper.length(value).nil?

    value.dup.freeze
  end

  def span_range(value)
    start_value = value.fetch(:provider_span_start)
    end_value = value.fetch(:provider_span_end)
    start_value...end_value
  end

  def range_within?(inner, outer)
    inner.begin >= outer.begin && inner.end <= outer.end
  end

  def ranges_overlap?(left, right)
    left.begin < right.end && right.begin < left.end
  end
end
