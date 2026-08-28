class Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossEvidenceExtractor
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES
  MAX_LINE_CONTENT_BYTES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
  MAX_PARENT_CONTENT_BYTES = 4_096
  MAX_PATH_BYTES = 160
  MAX_PAGE_DIMENSION = 10_000
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  EVIDENCE_KIND = "single_item_receipt_inner_tax_summary"
  STRUCTURED_SOURCE_PROVIDER = "azure_structured"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\r\n\u0085\u2028\u2029]/.freeze
  JPY_AMOUNT_PATTERN = /\A[\s[:punct:]¥￥$€£円]*(?<amount>(?:\d{1,3}(?:,\d{3})+|\d+))[\s[:punct:]¥￥$€£円]*\z/.freeze

  Result = Data.define(
    :kind,
    :string_index_type,
    :item_parent,
    :tax_detail_parent,
    :tax_description,
    :tax_amount,
    :document_tax_total,
    :summary_total
  ) do
    def initialize(
      string_index_type:,
      item_parent:,
      tax_detail_parent:,
      tax_description:,
      tax_amount:,
      document_tax_total:,
      summary_total:
    )
      super(
        kind: EVIDENCE_KIND.dup.freeze,
        string_index_type: string_index_type.dup.freeze,
        item_parent: item_parent.dup.freeze,
        tax_detail_parent: tax_detail_parent.dup.freeze,
        tax_description: tax_description.dup.freeze,
        tax_amount: tax_amount.dup.freeze,
        document_tax_total: document_tax_total.dup.freeze,
        summary_total: summary_total.dup.freeze
      )
    end
  end

  def self.call(analyze_result:, profile:, receipt_total:, receipt_tax:)
    new(
      analyze_result:,
      profile:,
      receipt_total:,
      receipt_tax:
    ).call
  end

  def initialize(analyze_result:, profile:, receipt_total:, receipt_tax:)
    @analyze_result = analyze_result
    @profile = profile
    @receipt_total = receipt_total
    @receipt_tax = receipt_tax
  end

  def call
    return unless provider_context_valid?
    return unless receipt_amounts_valid?

    fields = exact_document_fields
    return if fields.nil?

    item_parent = exact_single_parent(
      fields.dig("Items", "valueArray"),
      source_field_path: "documents[0].fields.Items[0]",
      item_index: 0
    )
    tax_entry, tax_detail_parent = exact_single_tax_detail(fields)
    return if item_parent.nil? || tax_entry.nil? || tax_detail_parent.nil?
    return unless ranges_disjoint?(item_parent, tax_detail_parent)
    return unless polygons_disjoint?(
      exact_polygon_bounds(fields.dig("Items", "valueArray", 0)),
      exact_polygon_bounds(tax_entry)
    )

    tax_description = exact_tax_description(tax_entry, parent: tax_detail_parent)
    tax_amount = exact_tax_amount(tax_entry, parent: tax_detail_parent)
    return if tax_description.nil? || tax_amount.nil?
    return unless ranges_disjoint?(tax_description, tax_amount)
    return unless tax_amount.fetch(:amount) == receipt_tax_amount

    document_tax_total = exact_document_tax_total(fields)
    return if document_tax_total.nil?
    return unless document_tax_total.fetch(:amount) == receipt_tax_amount
    return unless ranges_equal_or_disjoint?(tax_amount, document_tax_total)

    summary_total = exact_summary_total(fields)
    return if summary_total.nil?
    return unless summary_total.fetch(:amount) == receipt_total_amount
    return unless ranges_disjoint?(summary_total, item_parent)
    return unless ranges_disjoint?(summary_total, tax_detail_parent)

    Result.new(
      string_index_type: mapper.index_type,
      item_parent:,
      tax_detail_parent:,
      tax_description:,
      tax_amount:,
      document_tax_total:,
      summary_total:
    )
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  private

  attr_reader :analyze_result, :content, :lines, :mapper, :page_height, :page_width, :profile,
    :receipt_tax, :receipt_tax_amount, :receipt_total, :receipt_total_amount

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
      maximum_bytes: Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
    )
    return false if content.nil?

    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.one?

    @lines = validated_lines(pages.sole)
    lines.present?
  end

  def exact_document_fields
    documents = analyze_result["documents"]
    return unless documents.is_a?(Array) && documents.one? && documents.sole.is_a?(Hash)

    fields = documents.sole["fields"]
    fields if fields.is_a?(Hash)
  end

  def validated_lines(page)
    return unless page.is_a?(Hash)
    return unless page["pageNumber"] == 1 && page["unit"] == "pixel"

    @page_width = finite_positive_page_dimension(page["width"])
    @page_height = finite_positive_page_dimension(page["height"])
    return if page_width.nil? || page_height.nil?

    entries = page["lines"]
    return unless entries.is_a?(Array) && entries.size.between?(1, MAX_LINES)

    validated = entries.map.with_index { |entry, line_index| validated_line(entry, line_index:) }
    return if validated.any?(&:nil?)
    return unless validated.each_cons(2).all? do |left, right|
      left.fetch(:provider_span_end) <= right.fetch(:provider_span_start)
    end

    validated.freeze
  end

  def validated_line(entry, line_index:)
    return unless entry.is_a?(Hash)

    line_content = bounded_content(entry["content"], maximum_bytes: MAX_LINE_CONTENT_BYTES)
    return if line_content.nil? || line_content.match?(LINE_BREAK_PATTERN)

    span = exact_span(entry["spans"])
    return if span.nil?
    return unless mapper.length(line_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == line_content

    bounds = exact_line_polygon_bounds(entry)
    return if bounds.nil?

    {
      bounds:,
      page_index: 0,
      line_index:,
      source_field_path: "pages[0].lines[#{line_index}]".freeze,
      provider_span_start: span.fetch(:offset),
      provider_span_end: span.fetch(:offset) + span.fetch(:length)
    }.freeze
  end

  def exact_single_parent(values, source_field_path:, item_index: nil, tax_detail_index: nil)
    return unless values.is_a?(Array) && values.one? && values.sole.is_a?(Hash)

    entry = values.sole
    field_content = bounded_content(entry["content"], maximum_bytes: MAX_PARENT_CONTENT_BYTES)
    span = exact_span(entry["spans"])
    return if field_content.nil? || span.nil? || exact_polygon_bounds(entry).nil?
    return unless mapper.length(field_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == field_content

    structural_parent(
      source_field_path:,
      span:,
      item_index:,
      tax_detail_index:
    )
  end

  def exact_single_tax_detail(fields)
    values = fields.dig("TaxDetails", "valueArray")
    parent = exact_single_parent(
      values,
      source_field_path: "documents[0].fields.TaxDetails[0]",
      tax_detail_index: 0
    )
    return if parent.nil?

    [ values.sole, parent ]
  end

  def exact_tax_description(entry, parent:)
    value_object = entry["valueObject"]
    return unless value_object.is_a?(Hash)

    field = value_object["Description"]
    return unless field.is_a?(Hash)

    field_content = bounded_content(field["content"], maximum_bytes: MAX_LINE_CONTENT_BYTES)
    value_string = bounded_content(field["valueString"], maximum_bytes: MAX_LINE_CONTENT_BYTES)
    return if field_content.nil? || value_string.nil? || field_content != value_string
    return if field_content.match?(LINE_BREAK_PATTERN)
    return unless profile.respond_to?(:ocr_reference_pricing_single_structured_item_inner_tax_description_pattern)

    normalized = field_content.unicode_normalize(:nfkc).strip
    return unless normalized.match?(profile.ocr_reference_pricing_single_structured_item_inner_tax_description_pattern)
    return unless polygon_within?(exact_polygon_bounds(field), exact_polygon_bounds(entry))

    child_evidence(
      field:,
      field_content:,
      parent:,
      source_field_path: "documents[0].fields.TaxDetails[0].Description"
    )
  end

  def exact_tax_amount(entry, parent:)
    value_object = entry["valueObject"]
    return unless value_object.is_a?(Hash)

    field = value_object["Amount"]
    return unless field.is_a?(Hash)

    field_content = bounded_content(field["content"], maximum_bytes: MAX_LINE_CONTENT_BYTES)
    return if field_content.nil?
    return if field_content.match?(LINE_BREAK_PATTERN)

    lexeme_amount = exact_jpy_lexeme(field_content)
    return if lexeme_amount.nil?
    return unless exact_structured_currency_amount(field) == lexeme_amount
    return unless polygon_within?(exact_polygon_bounds(field), exact_polygon_bounds(entry))

    evidence = child_evidence(
      field:,
      field_content:,
      parent:,
      source_field_path: "documents[0].fields.TaxDetails[0].Amount"
    )
    evidence&.merge(amount: lexeme_amount)&.freeze
  end

  def child_evidence(field:, field_content:, parent:, source_field_path:)
    span = exact_span(field["spans"])
    return if span.nil?
    return unless mapper.length(field_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == field_content

    range = span_range(span)
    return unless range_within?(range, parent)

    owner = lines.select { |line| range_within?(range, line) }
    return unless owner.one?

    {
      source_provider: STRUCTURED_SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.dup.freeze,
      tax_detail_index: 0,
      page_index: owner.sole.fetch(:page_index),
      line_index: owner.sole.fetch(:line_index),
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: range.fetch(:provider_span_start),
      provider_span_end: range.fetch(:provider_span_end)
    }.freeze
  end

  def exact_document_tax_total(fields)
    field = fields["TotalTax"]
    return unless field.is_a?(Hash)

    field_content = bounded_content(field["content"], maximum_bytes: MAX_LINE_CONTENT_BYTES)
    return if field_content.nil?
    return if field_content.match?(LINE_BREAK_PATTERN)

    lexeme_amount = exact_jpy_lexeme(field_content)
    return if lexeme_amount.nil? || exact_structured_currency_amount(field) != lexeme_amount

    span = exact_span(field["spans"])
    return if span.nil?
    return unless mapper.length(field_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == field_content

    range = span_range(span)
    owner = lines.select { |line| range_within?(range, line) }
    return unless owner.one?
    return if exact_polygon_bounds(field).nil?

    {
      amount: lexeme_amount,
      source_provider: STRUCTURED_SOURCE_PROVIDER.dup.freeze,
      source_field_path: "documents[0].fields.TotalTax".freeze,
      page_index: owner.sole.fetch(:page_index),
      line_index: owner.sole.fetch(:line_index),
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: range.fetch(:provider_span_start),
      provider_span_end: range.fetch(:provider_span_end)
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

  def structural_parent(source_field_path:, span:, item_index:, tax_detail_index:)
    return if source_field_path.bytesize > MAX_PATH_BYTES

    {
      source_provider: STRUCTURED_SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.dup.freeze,
      item_index: item_index,
      tax_detail_index: tax_detail_index,
      provider_span_start: span.fetch(:offset),
      provider_span_end: span.fetch(:offset) + span.fetch(:length)
    }.compact.freeze
  end

  def bounded_content(value, maximum_bytes:)
    return unless value.is_a?(String) && value.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding)
    return if value.blank? || value.bytesize > maximum_bytes
    return if value.match?(CONTROL_CHARACTER_PATTERN)
    return if mapper.length(value).nil?

    value.dup.freeze
  end

  def exact_span(spans)
    return unless spans.is_a?(Array) && spans.one? && spans.sole.is_a?(Hash)

    offset = spans.sole["offset"]
    length = spans.sole["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer)
    return if offset.negative? || length <= 0
    return if offset > MAX_PROVIDER_SPAN || length > MAX_PROVIDER_SPAN - offset
    return if offset + length > mapper.length(content)

    { offset:, length: }
  end

  def finite_positive_page_dimension(value)
    return unless value.is_a?(Numeric) && value.finite? && value.positive?
    return if value > MAX_PAGE_DIMENSION

    Rational(value.to_s)
  rescue ArgumentError, NoMethodError, TypeError
    nil
  end

  def exact_polygon_bounds(field)
    regions = field.is_a?(Hash) ? field["boundingRegions"] : nil
    return unless regions.is_a?(Array) && regions.one? && regions.sole.is_a?(Hash)
    return unless regions.sole["pageNumber"] == 1

    polygon_bounds(regions.sole["polygon"])
  end

  def exact_line_polygon_bounds(line)
    polygon_bounds(line.is_a?(Hash) ? line["polygon"] : nil)
  end

  def polygon_bounds(polygon)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |coordinate| coordinate.is_a?(Numeric) && coordinate.finite? }

    xs = polygon.each_slice(2).map(&:first)
    ys = polygon.each_slice(2).map(&:last)
    return unless xs.all? { |coordinate| coordinate.between?(0, page_width) }
    return unless ys.all? { |coordinate| coordinate.between?(0, page_height) }

    left, right = xs.minmax
    top, bottom = ys.minmax
    return unless right > left && bottom > top

    {
      left: Rational(left.to_s),
      right: Rational(right.to_s),
      top: Rational(top.to_s),
      bottom: Rational(bottom.to_s)
    }.freeze
  rescue ArgumentError, NoMethodError, TypeError
    nil
  end

  def polygon_within?(inner, outer)
    inner && outer &&
      inner.fetch(:left) >= outer.fetch(:left) && inner.fetch(:right) <= outer.fetch(:right) &&
      inner.fetch(:top) >= outer.fetch(:top) && inner.fetch(:bottom) <= outer.fetch(:bottom)
  end

  def polygons_disjoint?(left, right)
    left && right &&
      (left.fetch(:right) <= right.fetch(:left) || right.fetch(:right) <= left.fetch(:left) ||
        left.fetch(:bottom) <= right.fetch(:top) || right.fetch(:bottom) <= left.fetch(:top))
  end

  def exact_jpy_lexeme(value)
    match = JPY_AMOUNT_PATTERN.match(value.unicode_normalize(:nfkc))
    return if match.nil?

    amount = ReceiptAmountService.parse_amount_or_nil(match[:amount])&.to_i
    amount if amount&.between?(1, MAX_AMOUNT)
  end

  def exact_structured_currency_amount(field)
    currency = field["valueCurrency"]
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

    value = currency["amount"]
    return unless value.is_a?(Integer) || value.is_a?(Float)
    return if value.is_a?(Float) && (!value.finite? || value.floor != value)
    return unless value.between?(1, MAX_AMOUNT)

    value.to_i
  rescue NoMethodError, TypeError
    nil
  end

  def receipt_amounts_valid?
    @receipt_total_amount = exact_whole_amount(receipt_total)
    @receipt_tax_amount = exact_whole_amount(receipt_tax)
    receipt_total_amount.present? && receipt_tax_amount.present?
  end

  def exact_whole_amount(value)
    return unless value.is_a?(Integer) || value.is_a?(Float)
    return if value.is_a?(Float) && (!value.finite? || value.floor != value)
    return unless value.between?(1, MAX_AMOUNT)

    value.to_i
  rescue NoMethodError, TypeError
    nil
  end

  def span_range(span)
    {
      provider_span_start: span.fetch(:offset),
      provider_span_end: span.fetch(:offset) + span.fetch(:length)
    }
  end

  def range_within?(inner, outer)
    inner.fetch(:provider_span_start) >= outer.fetch(:provider_span_start) &&
      inner.fetch(:provider_span_end) <= outer.fetch(:provider_span_end)
  end

  def ranges_disjoint?(left, right)
    left.fetch(:provider_span_end) <= right.fetch(:provider_span_start) ||
      right.fetch(:provider_span_end) <= left.fetch(:provider_span_start)
  end

  def ranges_equal_or_disjoint?(left, right)
    same_range = left.fetch(:provider_span_start) == right.fetch(:provider_span_start) &&
      left.fetch(:provider_span_end) == right.fetch(:provider_span_end)
    same_range || ranges_disjoint?(left, right)
  end
end
