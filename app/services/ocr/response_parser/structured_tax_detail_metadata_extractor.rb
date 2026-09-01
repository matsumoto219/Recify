class Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor
  MAX_PAGES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_PAGES
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES
  MAX_TAX_DETAILS = 20
  MAX_PARENT_SPANS = Ocr::ResponseParser::MAX_REFERENCE_PRICING_AUTHORITY_SPANS
  MAX_CONTENT_BYTES = Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  MAX_LINE_CONTENT_BYTES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
  MAX_PARENT_CONTENT_BYTES = 4_096
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  MAX_PAGE_DIMENSION = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PAGE_DIMENSION
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PATH_BYTES = 256
  MAX_RATE_SCALE = 6
  SOURCE_PROVIDER = "azure_structured"
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\r\n\u0085\u2028\u2029]/.freeze
  RATE_PATTERN = /\A[\s[:punct:]]*(?<rate>(?:0|[1-9][0-9]*)(?:\.[0-9]+)?)[\s]*[%％][\s[:punct:]]*\z/.freeze
  JPY_AMOUNT_PATTERN = /\A[\s[:punct:]¥￥円]*(?<amount>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+))[\s[:punct:]¥￥円]*\z/.freeze

  Result = Data.define(
    :source_provider,
    :provider_model_id,
    :provider_api_version,
    :string_index_type,
    :tax_details
  )

  def self.call(analyze_result:)
    new(analyze_result:).call
  end

  def initialize(analyze_result:)
    @analyze_result = analyze_result
  end

  def call
    return unless provider_context_valid?

    fields = exact_document_fields
    return if fields.nil?

    tax_details = exact_tax_details(fields)
    return if tax_details.nil?

    Result.new(
      source_provider: SOURCE_PROVIDER.dup.freeze,
      provider_model_id: SUPPORTED_MODEL_ID.dup.freeze,
      provider_api_version: SUPPORTED_API_VERSION.dup.freeze,
      string_index_type: mapper.index_type.dup.freeze,
      tax_details: deep_freeze(tax_details)
    )
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  private

  attr_reader :analyze_result, :content, :lines, :mapper, :page_dimensions

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
      maximum_bytes: MAX_CONTENT_BYTES,
      allow_line_breaks: true
    )
    return false if content.nil?

    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.size.between?(1, MAX_PAGES)

    @page_dimensions = {}
    @lines = pages.flat_map.with_index do |page, page_index|
      validated_page_lines(page, page_index:)
    end
    lines.present? && lines.size <= MAX_LINES && lines.each_cons(2).all? do |left, right|
      left.fetch(:provider_span_end) <= right.fetch(:provider_span_start)
    end
  rescue TypeError
    false
  end

  def exact_document_fields
    documents = analyze_result["documents"]
    return unless documents.is_a?(Array) && documents.one? && documents.sole.is_a?(Hash)

    fields = documents.sole["fields"]
    fields if fields.is_a?(Hash)
  end

  def validated_page_lines(page, page_index:)
    raise TypeError unless page.is_a?(Hash)
    raise TypeError unless page["pageNumber"] == page_index + 1 && page["unit"] == "pixel"

    width = finite_positive_dimension(page["width"])
    height = finite_positive_dimension(page["height"])
    raise TypeError if width.nil? || height.nil?

    @page_dimensions[page_index] = { width:, height: }.freeze
    entries = page["lines"]
    raise TypeError unless entries.is_a?(Array) && entries.size.between?(1, MAX_LINES)

    entries.map.with_index do |entry, line_index|
      validated_line(entry, page_index:, line_index:)
    end.tap do |validated|
      raise TypeError if validated.any?(&:nil?)
    end
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
      provider_span_start: span.begin,
      provider_span_end: span.end,
      bounds:
    }.freeze
  end

  def exact_tax_details(fields)
    field = fields["TaxDetails"]
    return unless field.is_a?(Hash)

    entries = field["valueArray"]
    return unless entries.is_a?(Array) && entries.size.between?(1, MAX_TAX_DETAILS)

    details = entries.map.with_index { |entry, index| exact_tax_detail(entry, index:) }
    return if details.any?(&:nil?)

    parent_spans = details.flat_map { |detail| detail.dig(:parent, :provider_spans) }
    return unless parent_spans.each_cons(2).all? do |left, right|
      left.fetch(:provider_span_end) <= right.fetch(:provider_span_start)
    end

    details.freeze
  end

  def exact_tax_detail(entry, index:)
    return unless entry.is_a?(Hash)

    parent = exact_parent(entry, index:)
    return if parent.nil?

    value_object = entry["valueObject"]
    return unless value_object.is_a?(Hash)

    path = "documents[0].fields.TaxDetails[#{index}]"
    rate = exact_rate_field(
      value_object["Rate"],
      parent:,
      source_field_path: "#{path}.Rate",
      tax_detail_index: index
    )
    net_amount = exact_money_field(
      value_object["NetAmount"],
      parent:,
      source_field_path: "#{path}.NetAmount",
      tax_detail_index: index,
      positive: true
    )
    tax_amount = exact_money_field(
      value_object["Amount"],
      parent:,
      source_field_path: "#{path}.Amount",
      tax_detail_index: index,
      positive: false
    )
    return if [ rate, net_amount, tax_amount ].any?(&:nil?)
    return if [ rate, net_amount, tax_amount ].combination(2).any? do |left, right|
      ranges_overlap?(left, right)
    end

    {
      tax_detail_index: index,
      parent: parent.except(:bounds),
      rate:,
      net_amount:,
      tax_amount:
    }.freeze
  end

  def exact_parent(entry, index:)
    parent_content = bounded_content(
      entry["content"],
      maximum_bytes: MAX_PARENT_CONTENT_BYTES,
      allow_line_breaks: true
    )
    spans = exact_provider_spans(entry["spans"])
    bounds = exact_field_region_bounds(entry)
    return if parent_content.nil? || spans.nil? || bounds.nil?
    return unless exact_provider_segments?(parent_content, spans)

    source_field_path = "documents[0].fields.TaxDetails[#{index}]"
    return if source_field_path.bytesize > MAX_PATH_BYTES

    {
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.freeze,
      tax_detail_index: index,
      provider_spans: spans.map do |span|
        {
          provider_span_start: span.begin,
          provider_span_end: span.end
        }.freeze
      end.freeze,
      bounds:
    }.freeze
  end

  def exact_rate_field(field, parent:, source_field_path:, tax_detail_index:)
    return unless field.is_a?(Hash)

    field_content = bounded_content(
      field["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_single_span(field["spans"])
    return if field_content.nil? || span.nil?
    return unless exact_provider_content?(field_content, span)

    match = RATE_PATTERN.match(field_content.unicode_normalize(:nfkc))
    return if match.nil?

    lexeme_rate = canonical_rate(BigDecimal(match[:rate]) / 100)
    provider_rate = canonical_rate(field["valueNumber"])
    return if lexeme_rate.nil? || provider_rate.nil? || lexeme_rate != provider_rate

    evidence = child_evidence(
      field,
      span:,
      parent:,
      source_field_path:,
      tax_detail_index:
    )
    evidence&.merge(rate: lexeme_rate)&.freeze
  end

  def exact_money_field(field, parent:, source_field_path:, tax_detail_index:, positive:)
    return unless field.is_a?(Hash)

    field_content = bounded_content(
      field["content"],
      maximum_bytes: MAX_LINE_CONTENT_BYTES,
      allow_line_breaks: false
    )
    span = exact_single_span(field["spans"])
    return if field_content.nil? || span.nil?
    return unless exact_provider_content?(field_content, span)

    amount = exact_jpy_lexeme(field_content)
    return if amount.nil? || exact_structured_currency_amount(field) != amount
    return if positive ? !amount.positive? : amount.negative?

    evidence = child_evidence(
      field,
      span:,
      parent:,
      source_field_path:,
      tax_detail_index:
    )
    evidence&.merge(amount:)&.freeze
  end

  def child_evidence(field, span:, parent:, source_field_path:, tax_detail_index:)
    return if source_field_path.bytesize > MAX_PATH_BYTES
    return unless parent.fetch(:provider_spans).one? do |parent_span|
      span.begin >= parent_span.fetch(:provider_span_start) &&
        span.end <= parent_span.fetch(:provider_span_end)
    end

    regions = exact_field_region_bounds(field)
    return if regions.nil?
    owners = lines.select do |line|
      span.begin >= line.fetch(:provider_span_start) && span.end <= line.fetch(:provider_span_end)
    end
    return unless owners.one?

    owner = owners.sole
    child_bounds = regions[owner.fetch(:page_index)]
    parent_bounds = parent.fetch(:bounds)[owner.fetch(:page_index)]
    return unless bounds_within?(child_bounds, parent_bounds)

    {
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.dup.freeze,
      tax_detail_index:,
      page_index: owner.fetch(:page_index),
      line_index: owner.fetch(:line_index),
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: span.begin,
      provider_span_end: span.end
    }.freeze
  end

  def exact_field_region_bounds(entry)
    regions = entry["boundingRegions"]
    return unless regions.is_a?(Array) && regions.size.between?(1, MAX_PAGES)

    pairs = regions.map do |region|
      return unless region.is_a?(Hash)

      page_number = region["pageNumber"]
      return unless page_number.is_a?(Integer) && page_number.between?(1, page_dimensions.size)

      page_index = page_number - 1
      bounds = polygon_bounds(region["polygon"], page_index:)
      return if bounds.nil?

      [ page_index, bounds ]
    end
    return unless pairs.map(&:first).uniq.size == pairs.size

    pairs.to_h.freeze
  end

  def exact_single_span(value)
    spans = exact_provider_spans(value)
    spans.sole if spans&.one?
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

      (offset...(offset + length))
    end
    return unless spans.each_cons(2).all? { |left, right| left.end <= right.begin }

    spans.freeze
  end

  def exact_provider_content?(value, span)
    return false unless mapper.length(value) == span.size

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

  def canonical_rate(value)
    return unless value.is_a?(Numeric) || value.is_a?(String)
    return if value.respond_to?(:finite?) && !value.finite?

    rate = BigDecimal(value.to_s)
    rate /= 100 if rate > 1
    return unless rate.positive? && rate <= 1

    text = rate.to_s("F").sub(/\.?0+\z/, "")
    scale = text.split(".", 2).fetch(1, "").length
    text.freeze if scale <= MAX_RATE_SCALE
  rescue ArgumentError
    nil
  end

  def exact_jpy_lexeme(value)
    match = JPY_AMOUNT_PATTERN.match(value.unicode_normalize(:nfkc))
    return if match.nil?

    amount = Integer(match[:amount].delete(","), exception: false)
    amount if amount&.between?(0, MAX_AMOUNT)
  rescue EncodingError
    nil
  end

  def exact_structured_currency_amount(field)
    currency = field["valueCurrency"]
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

    amount = currency["amount"]
    return unless amount.is_a?(Numeric) && amount.finite?

    decimal = BigDecimal(amount.to_s)
    decimal.to_i if decimal.frac.zero? && decimal.between?(0, MAX_AMOUNT)
  rescue ArgumentError
    nil
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

    tolerance = 1
    inner.fetch(:left) >= outer.fetch(:left) - tolerance &&
      inner.fetch(:top) >= outer.fetch(:top) - tolerance &&
      inner.fetch(:right) <= outer.fetch(:right) + tolerance &&
      inner.fetch(:bottom) <= outer.fetch(:bottom) + tolerance
  end

  def ranges_overlap?(left, right)
    left.fetch(:provider_span_start) < right.fetch(:provider_span_end) &&
      right.fetch(:provider_span_start) < left.fetch(:provider_span_end)
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

  def deep_freeze(value)
    case value
    when Hash
      value.each do |key, entry|
        deep_freeze(key)
        deep_freeze(entry)
      end
    when Array
      value.each { |entry| deep_freeze(entry) }
    else
      value.freeze
    end
    value.freeze
  end
end
