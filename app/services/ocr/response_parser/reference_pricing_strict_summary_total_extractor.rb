class Ocr::ResponseParser::ReferencePricingStrictSummaryTotalExtractor
  MAX_PAGES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_PAGES
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES
  MAX_LINE_CONTENT_BYTES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PAGE_DIMENSION = 10_000
  MAX_LABEL_LINE_DISTANCE = 3
  MAX_CENTER_DISTANCE_RATIO = Rational(2, 5)
  MIN_VERTICAL_OVERLAP_RATIO = Rational(1, 2)
  SOURCE_PROVIDER = "azure_document_total"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\r\n\u0085\u2028\u2029]/.freeze

  Result = Data.define(:amount, :label_evidence, :amount_evidence, :document_total_evidence) do
    def initialize(amount:, label_evidence:, amount_evidence:, document_total_evidence: nil)
      super(
        amount: amount,
        label_evidence: label_evidence.dup.freeze,
        amount_evidence: amount_evidence.dup.freeze,
        document_total_evidence: document_total_evidence&.dup&.freeze
      )
    end
  end

  def self.call(analyze_result:, profile:, total_field: nil)
    new(analyze_result:, profile:, total_field:).call
  end

  def initialize(analyze_result:, profile:, total_field:)
    @analyze_result = analyze_result
    @profile = profile
    @total_field = total_field
  end

  def call
    return unless provider_context_valid?

    results = same_line_results
    split = split_line_result
    results << split unless split.nil?
    results.sole if results.one?
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  private

  attr_reader :analyze_result, :content, :lines, :mapper, :profile, :structured_total, :total_field

  def provider_context_valid?
    return false unless analyze_result.is_a?(Hash)

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    return false if mapper.nil?

    @content = bounded_content(analyze_result["content"])
    return false if content.nil?

    @structured_total = exact_structured_total
    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.size.between?(1, MAX_PAGES)

    line_count = 0
    validated = pages.flat_map.with_index do |page, page_index|
      page_lines = validated_page_lines(page, page_index:)
      return false if page_lines.nil?
      return false if page_lines.size > MAX_LINES - line_count

      line_count += page_lines.size
      page_lines
    end

    @lines = validated.freeze
    true
  end

  def bounded_content(value)
    return unless value.is_a?(String) && value.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding)
    return if value.blank? || value.bytesize > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
    return if value.match?(CONTROL_CHARACTER_PATTERN)
    return if mapper.length(value).nil?

    value.dup.freeze
  end

  def validated_page_lines(page, page_index:)
    return unless page.is_a?(Hash) && page["lines"].is_a?(Array)
    return if page.key?("pageNumber") && page["pageNumber"] != page_index + 1

    width = finite_positive_page_dimension(page["width"])
    height = finite_positive_page_dimension(page["height"])

    entries = page["lines"].map.with_index do |entry, line_index|
      validated_line(entry, page_index:, line_index:, page_width: width, page_height: height)
    end
    return if entries.any?(&:nil?)
    return unless entries.each_cons(2).all? do |left, right|
      left.fetch(:provider_span_end) <= right.fetch(:provider_span_start)
    end

    entries
  end

  def validated_line(entry, page_index:, line_index:, page_width:, page_height:)
    return unless entry.is_a?(Hash)

    line_content = entry["content"]
    return unless line_content.is_a?(String) && line_content.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(line_content.encoding)
    return if line_content.blank? || line_content.bytesize > MAX_LINE_CONTENT_BYTES
    return if line_content.match?(CONTROL_CHARACTER_PATTERN) || line_content.match?(LINE_BREAK_PATTERN)

    span = exact_line_span(entry["spans"])
    return if span.nil?
    return unless mapper.length(line_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == line_content

    {
      content: line_content.dup.freeze,
      bounds: polygon_bounds(entry["polygon"], page_width:, page_height:),
      page_index: page_index,
      line_index: line_index,
      source_field_path: "pages[#{page_index}].lines[#{line_index}]".freeze,
      provider_span_start: span.fetch(:offset),
      provider_span_end: span.fetch(:offset) + span.fetch(:length)
    }.freeze
  end

  def exact_line_span(spans)
    return unless spans.is_a?(Array) && spans.size == 1 && spans.sole.is_a?(Hash)

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

  def polygon_bounds(value, page_width:, page_height:)
    return if page_width.nil? || page_height.nil?
    return unless value.is_a?(Array) && value.size == 8
    return unless value.all? { |coordinate| coordinate.is_a?(Numeric) && coordinate.finite? }

    xs = value.each_slice(2).map(&:first)
    ys = value.each_slice(2).map(&:last)
    return unless xs.all? { |coordinate| coordinate.between?(0, page_width) }
    return unless ys.all? { |coordinate| coordinate.between?(0, page_height) }

    left, right = xs.minmax
    top, bottom = ys.minmax
    return unless right > left && bottom > top

    {
      left: Rational(left.to_s),
      right: Rational(right.to_s),
      top: Rational(top.to_s),
      bottom: Rational(bottom.to_s),
      height: Rational((bottom - top).to_s)
    }.freeze
  rescue ArgumentError, NoMethodError, TypeError
    nil
  end

  def same_line_results
    lines.filter_map do |line|
      next unless line.fetch(:content).match?(profile.ocr_strict_receipt_summary_total_line_pattern)

      amount = strict_line_amount(line.fetch(:content))
      next if amount.nil?

      label_evidence = structural_evidence(line)
      document_total_evidence = exact_structured_amount_evidence(line, amount:)
      Result.new(
        amount:,
        label_evidence:,
        amount_evidence: document_total_evidence || label_evidence,
        document_total_evidence:
      )
    end
  end

  def split_line_result
    return if structured_total.nil?

    owners = lines.select { |line| owns_structured_total?(line) }
    return unless owners.one?

    amount_line = owners.sole
    return unless amount_line.fetch(:content).match?(profile.ocr_strict_receipt_summary_total_amount_line_pattern)
    return unless strict_line_amount(amount_line.fetch(:content)) == structured_total.fetch(:amount)

    labels = lines.select do |line|
      split_label_candidate?(line, amount_line:) && split_geometry_valid?(line, amount_line)
    end
    return unless labels.one?

    Result.new(
      amount: structured_total.fetch(:amount),
      label_evidence: structural_evidence(labels.sole),
      amount_evidence: structural_evidence(
        amount_line,
        span_start: structured_total.fetch(:span_start),
        span_end: structured_total.fetch(:span_end)
      ),
      document_total_evidence: structural_evidence(
        amount_line,
        span_start: structured_total.fetch(:span_start),
        span_end: structured_total.fetch(:span_end)
      )
    )
  end

  def exact_structured_total
    return unless total_field.is_a?(Hash)

    field_content = total_field["content"]
    spans = total_field["spans"]
    return unless field_content.is_a?(String) && field_content.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(field_content.encoding)
    return if field_content.blank? || field_content.bytesize > MAX_LINE_CONTENT_BYTES
    return unless spans.is_a?(Array) && spans.size == 1 && spans.sole.is_a?(Hash)

    span = exact_line_span(spans)
    return if span.nil?
    return unless mapper.length(field_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == field_content

    raw_amount = structured_total_amount
    return unless raw_amount.is_a?(Integer) || raw_amount.is_a?(Float)
    return if raw_amount.negative? || raw_amount > MAX_AMOUNT
    return if raw_amount.is_a?(Float) && (!raw_amount.finite? || raw_amount.floor != raw_amount)

    amount = raw_amount.to_i
    return unless strict_line_amount(field_content) == amount

    {
      amount: amount,
      span_start: span.fetch(:offset),
      span_end: span.fetch(:offset) + span.fetch(:length)
    }.freeze
  end

  def structured_total_amount
    currency = total_field["valueCurrency"]
    return total_field["valueNumber"] if currency.nil?
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

    currency["amount"]
  end

  def owns_structured_total?(line)
    structured_total.fetch(:span_start) >= line.fetch(:provider_span_start) &&
      structured_total.fetch(:span_end) <= line.fetch(:provider_span_end)
  end

  def exact_structured_amount_evidence(line, amount:)
    return if structured_total.nil?
    return unless structured_total.fetch(:amount) == amount && owns_structured_total?(line)

    structural_evidence(
      line,
      span_start: structured_total.fetch(:span_start),
      span_end: structured_total.fetch(:span_end)
    )
  end

  def split_label_candidate?(line, amount_line:)
    return false unless line.fetch(:page_index) == amount_line.fetch(:page_index)

    distance = amount_line.fetch(:line_index) - line.fetch(:line_index)
    distance.between?(1, MAX_LABEL_LINE_DISTANCE) &&
      line.fetch(:content).match?(profile.ocr_strict_receipt_summary_total_label_line_pattern)
  end

  def split_geometry_valid?(label_line, amount_line)
    label = label_line.fetch(:bounds)
    amount = amount_line.fetch(:bounds)
    return false if label.nil? || amount.nil?
    return false unless label.fetch(:right) < amount.fetch(:left)

    max_height = [ label.fetch(:height), amount.fetch(:height) ].max
    return false unless max_height.positive?

    label_center = (label.fetch(:top) + label.fetch(:bottom)) / 2
    amount_center = (amount.fetch(:top) + amount.fetch(:bottom)) / 2
    return false if (label_center - amount_center).abs / max_height > MAX_CENTER_DISTANCE_RATIO

    overlap = [ label.fetch(:bottom), amount.fetch(:bottom) ].min -
      [ label.fetch(:top), amount.fetch(:top) ].max
    overlap.positive? && overlap / max_height >= MIN_VERTICAL_OVERLAP_RATIO
  end

  def strict_line_amount(value)
    amounts = value.unicode_normalize(:nfkc).scan(/\d[\d,]*/).filter_map do |token|
      ReceiptAmountService.parse_amount_or_nil(token)&.to_i
    end.uniq
    amounts.sole if amounts.one?
  rescue EncodingError, ArgumentError, Enumerable::SoleItemExpectedError
    nil
  end

  def structural_evidence(line, span_start: line.fetch(:provider_span_start), span_end: line.fetch(:provider_span_end))
    {
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: line.fetch(:source_field_path),
      page_index: line.fetch(:page_index),
      line_index: line.fetch(:line_index),
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: span_start,
      provider_span_end: span_end
    }.freeze
  end
end
