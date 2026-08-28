class Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor
  MAX_LINES = 150
  MAX_LINE_CONTENT_BYTES = 512
  MAX_PAGE_DIMENSION = 10_000
  MAX_SOURCE_FIELD_PATH_BYTES = 160
  MAX_PROVIDER_SPAN_VALUE = Ocr::ResponseParser::AzureStringIndexMapper::MAX_PROVIDER_INDEX
  MAX_CONTENT_BYTES = Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  MAX_AMOUNT = 999_999_999_999
  MAX_EXISTING_TAX_DETAILS = 16
  MAX_EXCLUDED_SPAN_RANGES = 16
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  EVIDENCE_KIND = "single_item_receipt_gross_summary"
  SOURCE_PROVIDER = "azure_item_layout"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  LINE_BREAK_PATTERN = /[\r\n\u0085\u2028\u2029]/.freeze
  RATE_PATTERN = /(?<rate>\d+(?:\.\d+)?)\s*[%％]/.freeze
  MONEY_NUMBER_PATTERN = /\d[\d,]*/.freeze
  SPAN_RANGE_KEYS = %i[span_start span_end].freeze

  Result = Data.define(:kind, :string_index_type, :summary_total, :gross_tax_target) do
    def initialize(string_index_type:, summary_total:, gross_tax_target:)
      super(
        kind: EVIDENCE_KIND.dup.freeze,
        string_index_type: string_index_type.dup.freeze,
        summary_total: summary_total.dup.freeze,
        gross_tax_target: gross_tax_target.dup.freeze
      )
    end
  end

  def self.call(
    analyze_result:,
    profile:,
    receipt_total:,
    receipt_tax:,
    existing_tax_details:,
    excluded_span_ranges:
  )
    new(
      analyze_result:,
      profile:,
      receipt_total:,
      receipt_tax:,
      existing_tax_details:,
      excluded_span_ranges:
    ).call
  end

  def initialize(
    analyze_result:,
    profile:,
    receipt_total:,
    receipt_tax:,
    existing_tax_details:,
    excluded_span_ranges:
  )
    @analyze_result = analyze_result
    @profile = profile
    @receipt_total = receipt_total
    @receipt_tax = receipt_tax
    @existing_tax_details = existing_tax_details
    @excluded_span_ranges = excluded_span_ranges
  end

  def call
    return unless provider_context_valid?
    return unless amounts_valid?
    return unless existing_tax_details_valid?
    return unless excluded_span_ranges_valid?

    summary_total = exact_summary_total
    return if summary_total.nil?

    tax_group = exact_canonical_tax_group
    return if tax_group.nil?

    gross_tax_target = exact_gross_tax_target(tax_group)
    return if gross_tax_target.nil?
    return if evidence_overlaps_excluded_range?(summary_total)
    return if evidence_overlaps_excluded_range?(gross_tax_target)

    Result.new(
      string_index_type: mapper.index_type,
      summary_total: summary_total,
      gross_tax_target: gross_tax_target
    )
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  private

  attr_reader :analyze_result, :content, :excluded_span_ranges, :existing_tax_details,
    :lines, :mapper, :profile, :receipt_tax, :receipt_total

  def provider_context_valid?
    return false unless analyze_result.is_a?(Hash)
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return false unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    return false if mapper.nil?

    @content = bounded_content(analyze_result["content"])
    return false if content.nil?

    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.one?

    @lines = validated_lines(pages.sole)
    lines.present?
  end

  def bounded_content(value)
    return unless value.is_a?(String) && value.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding)
    return if value.blank? || value.bytesize > MAX_CONTENT_BYTES
    return if value.match?(CONTROL_CHARACTER_PATTERN)
    return if mapper.length(value).nil?

    value.dup.freeze
  end

  def validated_lines(page)
    return unless page.is_a?(Hash)
    return unless page["pageNumber"] == 1 && page["unit"] == "pixel"
    return unless finite_positive_page_dimension?(page["width"])
    return unless finite_positive_page_dimension?(page["height"])

    entries = page["lines"]
    return unless entries.is_a?(Array) && entries.size.between?(2, MAX_LINES)

    validated = entries.filter_map.with_index do |entry, line_index|
      validated_line(entry, line_index:)
    end
    return unless validated.size == entries.size
    return unless validated.each_cons(2).all? do |left, right|
      left.fetch(:provider_span_end) <= right.fetch(:provider_span_start)
    end

    validated.freeze
  end

  def validated_line(entry, line_index:)
    return unless entry.is_a?(Hash)

    line_content = entry["content"]
    return unless line_content.is_a?(String) && line_content.valid_encoding?
    return unless [ Encoding::UTF_8, Encoding::US_ASCII ].include?(line_content.encoding)
    return if line_content.blank? || line_content.bytesize > MAX_LINE_CONTENT_BYTES
    return if line_content.match?(CONTROL_CHARACTER_PATTERN) || line_content.match?(LINE_BREAK_PATTERN)

    span = exact_line_span(entry["spans"])
    return if span.nil?
    return unless mapper.length(line_content) == span.fetch(:length)
    return unless mapper.slice(
      content,
      offset: span.fetch(:offset),
      length: span.fetch(:length)
    ) == line_content

    source_field_path = "pages[0].lines[#{line_index}]"
    return if source_field_path.bytesize > MAX_SOURCE_FIELD_PATH_BYTES

    {
      content: line_content.dup.freeze,
      source_provider: SOURCE_PROVIDER.dup.freeze,
      source_field_path: source_field_path.freeze,
      page_index: 0,
      line_index: line_index,
      string_index_type: mapper.index_type.dup.freeze,
      provider_span_start: span.fetch(:offset),
      provider_span_end: span.fetch(:offset) + span.fetch(:length)
    }.freeze
  end

  def exact_line_span(spans)
    return unless spans.is_a?(Array) && spans.one? && spans.sole.is_a?(Hash)

    offset = spans.sole["offset"]
    length = spans.sole["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer)
    return if offset.negative? || length <= 0
    return if offset > MAX_PROVIDER_SPAN_VALUE || length > MAX_PROVIDER_SPAN_VALUE - offset
    return if offset + length > mapper.length(content)

    { offset:, length: }
  end

  def finite_positive_page_dimension?(value)
    value.is_a?(Numeric) && value.finite? && value.positive? && value <= MAX_PAGE_DIMENSION
  rescue NoMethodError, TypeError
    false
  end

  def amounts_valid?
    exact_amount?(receipt_total, positive: true) && exact_amount?(receipt_tax, positive: true)
  end

  def existing_tax_details_valid?
    existing_tax_details.is_a?(Array) &&
      existing_tax_details.size <= MAX_EXISTING_TAX_DETAILS &&
      existing_tax_details.all?(Hash)
  end

  def excluded_span_ranges_valid?
    return false unless excluded_span_ranges.is_a?(Array)
    return false unless excluded_span_ranges.size.between?(1, MAX_EXCLUDED_SPAN_RANGES)
    return false unless excluded_span_ranges.all? { |range| valid_excluded_span_range?(range) }

    excluded_span_ranges.each_cons(2).all? do |left, right|
      left.fetch(:span_end) <= right.fetch(:span_start)
    end
  end

  def valid_excluded_span_range?(range)
    return false unless range.is_a?(Hash) && range.keys.sort == SPAN_RANGE_KEYS.sort

    span_start = range[:span_start]
    span_end = range[:span_end]
    span_start.is_a?(Integer) && span_end.is_a?(Integer) &&
      span_start.between?(0, MAX_PROVIDER_SPAN_VALUE) && span_end > span_start &&
      span_end <= mapper.length(content)
  rescue ArgumentError, TypeError
    false
  end

  def exact_summary_total
    descriptor = Ocr::ResponseParser::ReferencePricingStrictSummaryTotalExtractor.call(
      analyze_result:,
      profile:,
      total_field: analyze_result.dig("documents", 0, "fields", "Total")
    )
    return unless descriptor&.amount == receipt_total

    descriptor.amount_evidence.merge(
      amount: descriptor.amount,
      source_provider: SOURCE_PROVIDER.dup.freeze
    ).freeze
  end

  def exact_canonical_tax_group
    details = Analysis.tax_detail_line_evidence(
      lines: lines.map { |line| line.fetch(:content) },
      receipt_total: receipt_total,
      receipt_tax: receipt_tax,
      existing_tax_details: existing_tax_details,
      profile: profile
    )
    return unless details.is_a?(Array) && details.one?

    detail = details.sole
    return unless detail.is_a?(Hash)

    rate = exact_rate(detail[:rate])
    net_amount = exact_amount(detail[:net_amount], positive: false)
    tax_amount = exact_amount(detail[:amount], positive: true)
    return if rate.nil? || net_amount.nil? || tax_amount.nil?

    gross_amount = net_amount + tax_amount
    return unless gross_amount == receipt_total && tax_amount == receipt_tax
    return unless tax_amount == tax_from_gross(gross_amount, rate)

    {
      rate: canonical_decimal(rate).freeze,
      net_amount: net_amount,
      tax_amount: tax_amount,
      gross_amount: gross_amount
    }.freeze
  end

  def exact_gross_tax_target(tax_group)
    matches = lines.filter_map do |line|
      next unless gross_tax_target_line?(line.fetch(:content))

      rate = exact_rate_from_line(line.fetch(:content))
      gross_amount = exact_money_amount(line.fetch(:content), remove_rate: true)
      next unless rate == tax_group.fetch(:rate)
      next unless gross_amount == tax_group.fetch(:gross_amount)

      structural_evidence(line).merge(tax_group).freeze
    end
    matches.sole if matches.one?
  end

  def gross_tax_target_line?(value)
    text = normalized_text(value)
    return false if text.match?(profile.analysis_tax_amount_description_pattern)
    return false if text.match?(profile.amount_tax_detail_net_pattern)
    return false if text.match?(profile.amount_tax_detail_intermediate_pattern)

    text.match?(profile.analysis_tax_target_marker_pattern) ||
      text.match?(profile.amount_tax_detail_gross_pattern)
  end

  def exact_rate_from_line(value)
    matches = normalized_text(value).to_enum(:scan, RATE_PATTERN).map do
      Regexp.last_match[:rate]
    end
    return unless matches.one? && matches.sole.bytesize <= 16

    rate = BigDecimal(matches.sole) / 100
    canonical_decimal(rate) if rate.positive? && rate <= 1
  rescue ArgumentError, TypeError
    nil
  end

  def exact_money_amount(value, remove_rate:)
    text = normalized_text(value)
    text = text.gsub(RATE_PATTERN, " ") if remove_rate
    amounts = text.scan(MONEY_NUMBER_PATTERN).filter_map do |token|
      normalized_token = token.delete(",")
      next if normalized_token.bytesize > 32

      amount = Integer(normalized_token, 10)
      amount if exact_amount?(amount, positive: true)
    end.uniq
    amounts.sole if amounts.one?
  rescue ArgumentError, TypeError
    nil
  end

  def exact_rate(value)
    return unless value.is_a?(BigDecimal) && value.finite? && value.positive? && value <= 1

    value
  end

  def exact_amount?(value, positive:)
    value.is_a?(Integer) && value <= MAX_AMOUNT && (positive ? value.positive? : !value.negative?)
  end

  def exact_amount(value, positive:)
    value if exact_amount?(value, positive:)
  end

  def structural_evidence(line)
    line.except(:content).dup.freeze
  end

  def tax_from_gross(gross_amount, rate)
    ReceiptAmountService.apply_rounding(
      BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate),
      :floor
    )
  end

  def evidence_overlaps_excluded_range?(evidence)
    excluded_span_ranges.any? do |range|
      evidence.fetch(:provider_span_start) < range.fetch(:span_end) &&
        range.fetch(:span_start) < evidence.fetch(:provider_span_end)
    end
  end

  def normalized_text(value)
    value.unicode_normalize(:nfkc)
  end

  def canonical_decimal(decimal)
    value = decimal.to_s("F")
    integer, fraction = value.split(".", 2)
    fraction = fraction&.sub(/0+\z/, "")
    fraction.present? ? "#{integer}.#{fraction}" : integer
  end
end
