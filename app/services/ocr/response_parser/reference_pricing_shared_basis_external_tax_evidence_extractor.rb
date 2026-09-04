class Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxEvidenceExtractor
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES
  MAX_LINE_CONTENT_BYTES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  MAX_PAGE_DIMENSION = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PAGE_DIMENSION
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PATH_BYTES = 160
  FIELD_LINE_BOUNDS_TOLERANCE = 2
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  EVIDENCE_KIND = "shared_basis_external_tax_summary"
  SOURCE_PROVIDER = "azure_structured"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\r\n\u0085\u2028\u2029]/.freeze
  JPY_AMOUNT_PATTERN = /\A\s*(?:[¥￥]\s*)?(?<amount>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+))\s*(?:円)?\s*\z/.freeze

  Result = Data.define(
    :kind,
    :string_index_type,
    :tax_detail_index,
    :subtotal,
    :document_tax_total,
    :summary_total
  ) do
    def initialize(string_index_type:, tax_detail_index:, subtotal:, document_tax_total:, summary_total:)
      super(
        kind: EVIDENCE_KIND.dup.freeze,
        string_index_type: string_index_type.dup.freeze,
        tax_detail_index:,
        subtotal: subtotal.dup.freeze,
        document_tax_total: document_tax_total.dup.freeze,
        summary_total: summary_total.dup.freeze
      )
    end
  end

  def self.call(
    analyze_result:,
    profile:,
    receipt_subtotal:,
    receipt_total:,
    receipt_tax:,
    tax_detail_structural_metadata:
  )
    new(
      analyze_result:,
      profile:,
      receipt_subtotal:,
      receipt_total:,
      receipt_tax:,
      tax_detail_structural_metadata:
    ).call
  end

  def initialize(
    analyze_result:,
    profile:,
    receipt_subtotal:,
    receipt_total:,
    receipt_tax:,
    tax_detail_structural_metadata:
  )
    @analyze_result = analyze_result
    @profile = profile
    @receipt_subtotal = receipt_subtotal
    @receipt_total = receipt_total
    @receipt_tax = receipt_tax
    @tax_detail_structural_metadata = tax_detail_structural_metadata
  end

  def call
    return unless provider_context_valid?

    amounts = exact_receipt_amounts
    return if amounts.nil?

    tax_detail = exact_tax_detail_metadata
    return if tax_detail.nil?

    fields = exact_document_fields
    return if fields.nil?

    subtotal = exact_money_field(fields["Subtotal"], source_field_path: "documents[0].fields.Subtotal")
    document_tax_total = exact_money_field(
      fields["TotalTax"],
      source_field_path: "documents[0].fields.TotalTax"
    )
    summary_total = exact_money_field(fields["Total"], source_field_path: "documents[0].fields.Total")
    return if [ subtotal, document_tax_total, summary_total ].any?(&:nil?)
    return unless document_tax_total.slice(:provider_span_start, :provider_span_end) ==
      tax_detail.fetch(:tax_amount).slice(:provider_span_start, :provider_span_end)
    return unless [ subtotal, summary_total ].all? do |entry|
      range_disjoint_from_tax_detail?(entry, tax_detail.fetch(:parent))
    end

    expected = {
      subtotal: amounts.fetch(:subtotal),
      tax: amounts.fetch(:tax),
      total: amounts.fetch(:total)
    }
    actual = {
      subtotal: subtotal.fetch(:amount),
      tax: document_tax_total.fetch(:amount),
      total: summary_total.fetch(:amount)
    }
    return unless actual == expected
    return unless tax_detail.dig(:net_amount, :amount) == expected.fetch(:subtotal)
    return unless tax_detail.dig(:tax_amount, :amount) == expected.fetch(:tax)
    return unless expected.fetch(:subtotal) + expected.fetch(:tax) == expected.fetch(:total)

    Result.new(
      string_index_type: mapper.index_type,
      tax_detail_index: 0,
      subtotal:,
      document_tax_total:,
      summary_total:
    )
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  private

  attr_reader :analyze_result, :content, :lines, :mapper, :page_height, :page_width, :profile,
    :receipt_subtotal, :receipt_tax, :receipt_total, :tax_detail_structural_metadata

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

    @lines = validated_lines(pages.sole)
    lines.present?
  end

  def validated_lines(page)
    return unless page.is_a?(Hash)
    return unless page["pageNumber"] == 1 && page["unit"] == "pixel"

    @page_width = finite_positive_dimension(page["width"])
    @page_height = finite_positive_dimension(page["height"])
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

    line_content = bounded_content(
      entry["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_span(entry["spans"])
    bounds = polygon_bounds(entry["polygon"])
    return if line_content.nil? || span.nil? || bounds.nil?
    return unless exact_provider_content?(line_content, span)

    {
      line_index:,
      provider_span_start: span.begin,
      provider_span_end: span.end,
      bounds:
    }.freeze
  end

  def exact_receipt_amounts
    subtotal = exact_integer_amount(receipt_subtotal)
    tax = exact_integer_amount(receipt_tax)
    total = exact_integer_amount(receipt_total)
    return if subtotal.nil? || tax.nil? || total.nil?

    { subtotal:, tax:, total: }.freeze
  end

  def exact_tax_detail_metadata
    metadata = tax_detail_structural_metadata
    return unless metadata.is_a?(Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result)
    return unless metadata.source_provider == SOURCE_PROVIDER
    return unless metadata.provider_model_id == SUPPORTED_MODEL_ID
    return unless metadata.provider_api_version == SUPPORTED_API_VERSION
    return unless metadata.string_index_type == mapper.index_type
    return unless metadata.tax_details.is_a?(Array) && metadata.tax_details.one?

    detail = metadata.tax_details.sole
    return unless detail.fetch(:tax_detail_index) == 0

    tax_inclusion = detail[:tax_inclusion_evidence]
    return unless tax_inclusion.is_a?(Hash)
    return unless tax_inclusion[:kind] == "external_tax" && tax_inclusion[:tax_inclusion] == "net"
    return unless profile.respond_to?(:ocr_reference_pricing_shared_basis_external_tax_description_pattern)

    detail
  end

  def exact_document_fields
    documents = analyze_result["documents"]
    return unless documents.is_a?(Array) && documents.one? && documents.sole.is_a?(Hash)

    fields = documents.sole["fields"]
    fields if fields.is_a?(Hash)
  end

  def exact_money_field(field, source_field_path:)
    return unless field.is_a?(Hash) && source_field_path.bytesize <= MAX_PATH_BYTES

    field_content = bounded_content(
      field["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_span(field["spans"])
    return if field_content.nil? || span.nil? || !exact_provider_content?(field_content, span)

    amount = exact_jpy_lexeme(field_content)
    return if amount.nil? || exact_structured_currency_amount(field) != amount

    regions = field["boundingRegions"]
    return unless regions.is_a?(Array) && regions.one? && regions.sole.is_a?(Hash)
    return unless regions.sole["pageNumber"] == 1

    bounds = polygon_bounds(regions.sole["polygon"])
    return if bounds.nil?

    owners = lines.select do |line|
      span.begin >= line.fetch(:provider_span_start) && span.end <= line.fetch(:provider_span_end)
    end
    return unless owners.one? && bounds_within?(bounds, owners.sole.fetch(:bounds))

    {
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.dup.freeze,
      page_index: 0,
      line_index: owners.sole.fetch(:line_index),
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: span.begin,
      provider_span_end: span.end,
      amount:
    }.freeze
  end

  def range_disjoint_from_tax_detail?(entry, parent)
    spans = parent[:provider_spans]
    spans.is_a?(Array) && spans.all? do |span|
      entry.fetch(:provider_span_end) <= span.fetch(:provider_span_start) ||
        span.fetch(:provider_span_end) <= entry.fetch(:provider_span_start)
    end
  end

  def exact_span(value)
    return unless value.is_a?(Array) && value.one? && value.sole.is_a?(Hash)

    offset = value.sole["offset"]
    length = value.sole["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer)
    return if offset.negative? || length <= 0
    return if offset > MAX_PROVIDER_SPAN || length > MAX_PROVIDER_SPAN - offset
    return if offset + length > mapper.length(content)

    (offset...(offset + length))
  end

  def exact_provider_content?(value, span)
    mapper.length(value) == span.size &&
      mapper.slice(content, offset: span.begin, length: span.size) == value
  end

  def exact_jpy_lexeme(value)
    match = JPY_AMOUNT_PATTERN.match(value.unicode_normalize(:nfkc))
    return if match.nil?

    exact_integer_amount(match[:amount].delete(","))
  rescue EncodingError
    nil
  end

  def exact_structured_currency_amount(field)
    currency = field["valueCurrency"]
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

    exact_integer_amount(currency["amount"])
  end

  def exact_integer_amount(value)
    return unless value.is_a?(Numeric) || value.is_a?(String)
    return if value.respond_to?(:finite?) && !value.finite?

    amount = BigDecimal(value.to_s)
    amount.to_i if amount.frac.zero? && amount.between?(0, MAX_AMOUNT)
  rescue ArgumentError
    nil
  end

  def polygon_bounds(polygon)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |value| value.is_a?(Numeric) && value.finite? }

    xs = polygon.each_slice(2).map(&:first)
    ys = polygon.each_slice(2).map(&:last)
    return unless xs.all? { |value| value.between?(0, page_width) }
    return unless ys.all? { |value| value.between?(0, page_height) }

    bounds = { left: xs.min, top: ys.min, right: xs.max, bottom: ys.max }
    bounds.freeze if bounds[:right] > bounds[:left] && bounds[:bottom] > bounds[:top]
  end

  def bounds_within?(inner, outer)
    inner.fetch(:left) >= outer.fetch(:left) - FIELD_LINE_BOUNDS_TOLERANCE &&
      inner.fetch(:top) >= outer.fetch(:top) - FIELD_LINE_BOUNDS_TOLERANCE &&
      inner.fetch(:right) <= outer.fetch(:right) + FIELD_LINE_BOUNDS_TOLERANCE &&
      inner.fetch(:bottom) <= outer.fetch(:bottom) + FIELD_LINE_BOUNDS_TOLERANCE
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

    value
  end
end
