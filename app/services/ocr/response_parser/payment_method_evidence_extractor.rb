class Ocr::ResponseParser::PaymentMethodEvidenceExtractor
  MAX_PAGES = 8
  MAX_LINES = 150
  MAX_LINE_BYTES = 500
  MAX_FIELD_NODES = 512
  MAX_FIELD_ENTRIES = 100
  MAX_FIELD_DEPTH = 8
  MAX_FIELD_SPANS = 16
  MAX_PAGE_DIMENSION = 10_000
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  OWNER_FIELDS = %w[Items MerchantName MerchantAddress MerchantPhoneNumber].freeze
  CONTROL_PATTERN = /[\u0000-\u001F\u007F]/.freeze

  def self.call(...)
    new(...).call
  end

  def initialize(analyze_result:, fields:, lines:, profile:)
    @analyze_result = analyze_result
    @fields = fields
    @lines = lines
    @profile = profile
  end

  def call
    return unless analyze_result.is_a?(Hash) && fields.is_a?(Hash) && fields.size <= MAX_FIELD_ENTRIES
    return unless analyze_result["modelId"] == SUPPORTED_MODEL_ID && analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @content = analyze_result["content"]
    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    return unless mapper && content.is_a?(String) && mapper.byte_range_for_span(content, offset: 0, length: 0)

    entries = line_entries
    return unless entries && lines == entries.map { |entry| entry[:text] }

    pairs = entries.each_cons(2).select do |label, value|
      label[:text].match?(profile.ocr_payment_method_label_pattern) && same_row?(label, value) &&
        !value[:text].match?(profile.ocr_payment_schedule_value_pattern)
    end
    return unless pairs.one?

    label, value = pairs.first
    methods = profile.ocr_payment_method_value_patterns.filter_map { |method, pattern| method if value[:text].match?(pattern) }
    return unless methods.one?
    return if conflicting_line?(entries, label, value, methods.sole) || conflicting_structured_payment?(methods.sole)

    spans = owner_spans
    return unless spans && spans.none? { |span| span_overlap?(span, label[:span]) || span_overlap?(span, value[:span]) }

    Analysis.payment_method_evidence(
      {
        source_kind: "azure_same_row", method: methods.sole, page_index: label[:page_index],
        label_line_index: label[:index], method_line_index: value[:index],
        label_path: label[:path], method_path: value[:path], label_span: label[:span], method_span: value[:span],
        string_index_type: mapper.index_type
      },
      lines:,
      profile:
    )
  end

  private

  attr_reader :analyze_result, :fields, :lines, :profile, :content, :mapper

  def line_entries
    pages = analyze_result["pages"]
    return unless pages.is_a?(Array) && pages.size.between?(1, MAX_PAGES)
    return unless lines.is_a?(Array) && lines.size.between?(2, MAX_LINES)

    entries = []
    pages.each_with_index do |page, page_index|
      return unless page.is_a?(Hash) && page["lines"].is_a?(Array)
      return unless valid_dimension?(page["width"]) && valid_dimension?(page["height"])
      return if entries.size + page["lines"].size > MAX_LINES

      page["lines"].each_with_index do |line, line_index|
        entry = line_entry(line, page)
        return unless entry

        entries << entry.merge(index: entries.size, page_index:, line_index:, path: "pages[#{page_index}].lines[#{line_index}]")
      end
    end
    return if entries.sort_by { |entry| entry[:span][:offset] }.each_cons(2).any? do |first, second|
      span_overlap?(first[:span], second[:span])
    end

    entries
  end

  def line_entry(line, page)
    return unless line.is_a?(Hash)

    text = line["content"]
    return unless text.is_a?(String) && text.valid_encoding? && (text.encoding == Encoding::UTF_8 || text.ascii_only?)
    return if text.bytesize > MAX_LINE_BYTES || text.match?(CONTROL_PATTERN)
    return unless line["spans"].is_a?(Array) && line["spans"].one?

    span = bounded_span(line["spans"].first)
    return unless span && mapper.slice(content, **span) == text

    box = polygon_box(line["polygon"], page)
    normalized = text.encode(Encoding::UTF_8).unicode_normalize(:nfkc).downcase.gsub(/[[:space:]]+/, " ").strip
    return unless box && normalized.present? && normalized.bytesize <= MAX_LINE_BYTES

    { text: normalized, span:, box: }
  end

  def bounded_span(value)
    return unless value.is_a?(Hash) && value.size == 2 && value.key?("offset") && value.key?("length")

    offset = value["offset"]
    length = value["length"]
    return unless length.is_a?(Integer) && length.positive?
    return unless mapper.byte_range_for_span(content, offset:, length:)

    { offset:, length: }
  end

  def polygon_box(polygon, page)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |coordinate| finite_coordinate?(coordinate) }

    points = polygon.each_slice(2).to_a
    return unless points.all? { |x, y| x.between?(0, page["width"]) && y.between?(0, page["height"]) }

    crosses = points.each_index.map do |index|
      x1, y1 = points[index]
      x2, y2 = points[(index + 1) % points.size]
      x3, y3 = points[(index + 2) % points.size]
      (x2 - x1) * (y3 - y2) - (y2 - y1) * (x3 - x2)
    end
    return unless crosses.all?(&:positive?) || crosses.all?(&:negative?)

    left, right = points.map(&:first).minmax
    top, bottom = points.map(&:last).minmax
    { left:, right:, top:, bottom: }
  end

  def finite_coordinate?(value)
    (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.between?(0, MAX_PAGE_DIMENSION)
  end

  def valid_dimension?(value)
    finite_coordinate?(value) && value.positive?
  end

  def same_row?(label, value)
    return false unless label[:page_index] == value[:page_index] && label[:line_index] + 1 == value[:line_index]

    first = label[:box]
    second = value[:box]
    height = [ first[:bottom] - first[:top], second[:bottom] - second[:top] ].max
    overlap = [ first[:bottom], second[:bottom] ].min - [ first[:top], second[:top] ].max
    first[:right] <= second[:left] && overlap.fdiv(height) >= Rational(1, 2)
  end

  def conflicting_line?(entries, label, value, method)
    group = {
      left: label[:box][:left], right: value[:box][:right],
      top: [ label[:box][:top], value[:box][:top] ].min,
      bottom: [ label[:box][:bottom], value[:box][:bottom] ].max
    }
    entries.any? do |entry|
      next false if [ label[:index], value[:index] ].include?(entry[:index])
      next true if entry[:page_index] == label[:page_index] && boxes_overlap?(group, entry[:box])

      text = entry[:text]
      next false if text.match?(profile.analysis_payment_sale_or_promo_pattern) ||
        text.match?(profile.analysis_fallback_payment_metadata_label_pattern) ||
        text.match?(profile.analysis_payment_card_slip_title_pattern)
      next false unless text.match?(profile.fallback_payment_method_transaction_context_pattern)

      profile.fallback_payment_method_patterns.any? do |other, patterns|
        other != method && patterns.any? { |pattern| text.match?(pattern) }
      end
    end
  end

  def boxes_overlap?(first, second)
    [ first[:right], second[:right] ].min > [ first[:left], second[:left] ].max &&
      [ first[:bottom], second[:bottom] ].min > [ first[:top], second[:top] ].max
  end

  def conflicting_structured_payment?(method)
    field = fields["Payments"]
    return false if field.nil?
    return true unless field.is_a?(Hash) && field["valueArray"].is_a?(Array) && field["valueArray"].size <= MAX_FIELD_ENTRIES

    field["valueArray"].any? do |payment|
      object = payment["valueObject"] if payment.is_a?(Hash)
      method_field = object["Method"] if object.is_a?(Hash)
      value = method_field["valueString"] if method_field.is_a?(Hash)
      next true unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_LINE_BYTES

      matches = profile.ocr_payment_method_value_patterns.filter_map { |key, pattern| key if value.match?(pattern) }
      matches != [ method ]
    end
  end

  def owner_spans
    return unless OWNER_FIELDS.all? { |key| !fields.key?(key) || fields[key].is_a?(Hash) }

    owners = OWNER_FIELDS.select { |key| fields[key].present? }
    pending = owners.map { |key| [ fields[key], 0, key ] }
    spans = []
    located_owners = []
    visited = 0
    until pending.empty?
      value, depth, owner = pending.pop
      visited += 1
      return if visited > MAX_FIELD_NODES || depth > MAX_FIELD_DEPTH

      if value.is_a?(Hash)
        return if value.size > MAX_FIELD_ENTRIES
        if value.key?("spans")
          return unless value["spans"].is_a?(Array) && value["spans"].size.between?(1, MAX_FIELD_SPANS)

          found = value["spans"].map { |span| bounded_span(span) }
          return if found.any?(&:nil?)

          spans.concat(found)
          located_owners |= [ owner ]
        elsif value["content"].present?
          return
        end
        value.each do |key, child|
          pending << [ child, depth + 1, owner ] if key != "spans" && (child.is_a?(Hash) || child.is_a?(Array))
        end
      elsif value.is_a?(Array)
        return if value.size > MAX_FIELD_ENTRIES

        value.each { |child| pending << [ child, depth + 1, owner ] }
      end
      return if pending.size > MAX_FIELD_NODES
    end
    spans if owners.all? { |owner| located_owners.include?(owner) }
  end

  def span_overlap?(first, second)
    first[:offset] < second[:offset] + second[:length] && second[:offset] < first[:offset] + first[:length]
  end
end
