class Ocr::ResponseParser::StoreNameLayoutExtractor
  MAX_PAGES = 100
  MAX_LINES = 10_000
  MAX_PAGE_DIMENSION = 10_000
  COORDINATE_SCALE = 10_000
  CONTROL_PATTERN = /[\u0000-\u001F\u007F]/.freeze

  def self.call(analyze_result:, evidence:)
    new(analyze_result:, evidence:).call
  end

  def initialize(analyze_result:, evidence:)
    @analyze_result = analyze_result
    @evidence = Analysis.store_name_evidence(evidence)
  end

  def call
    return unless evidence && !evidence[:invalid]
    return unless analyze_result.is_a?(Hash) && bounded_pages?

    content = analyze_result["content"]
    return unless content.is_a?(String) && content.bytesize <= Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES

    @content = content.dup.freeze
    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    return unless mapper&.byte_range_for_span(@content, offset: 0, length: 0)

    entries = evidence[:candidates].filter_map { |candidate| extract_entry(candidate) }
    Analysis.store_name_layout({ scope: "provider_line", coordinate_scale: COORDINATE_SCALE, entries: }, evidence:)
  end

  private

  attr_reader :analyze_result, :evidence, :content, :mapper

  def bounded_pages?
    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.size <= MAX_PAGES

    line_count = 0
    pages.all? do |page|
      next false unless page.is_a?(Hash) && page["lines"].is_a?(Array)

      line_count += page["lines"].size
      line_count <= MAX_LINES
    end
  end

  def extract_entry(candidate)
    return unless candidate[:span_state] == "exact" && candidate[:string_index_type] == analyze_result["stringIndexType"]
    return unless candidate[:page_index].is_a?(Integer) && candidate[:provider_line_index].is_a?(Integer)

    page = analyze_result["pages"][candidate[:page_index]]
    return unless page

    line = page["lines"][candidate[:provider_line_index]]
    return unless line.is_a?(Hash)

    span = exact_line_span(line)
    return unless span && contains_span?(span, candidate[:span])

    bounds = normalized_bounds(line["polygon"], page)
    return unless bounds

    {
      candidate_id: candidate[:candidate_id], page_index: candidate[:page_index],
      provider_line_index: candidate[:provider_line_index], line_span: span, bounds:
    }
  end

  def exact_line_span(line)
    spans = line["spans"]
    return unless spans.is_a?(Array) && spans.size == 1 && spans.first.is_a?(Hash)

    span = spans.first
    return unless span.size == 2 && span.key?("offset") && span.key?("length")

    offset = span["offset"]
    length = span["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer) && length.positive?

    mapped_text = normalized_text(mapper.slice(content, offset:, length:))
    return unless mapped_text && mapped_text == normalized_text(line["content"])

    { offset:, length: }
  end

  def contains_span?(parent, child)
    parent[:offset] <= child[:offset] &&
      child[:offset] + child[:length] <= parent[:offset] + parent[:length]
  end

  def normalized_text(value)
    return unless value.is_a?(String) && value.valid_encoding?
    return unless value.encoding == Encoding::UTF_8 || value.ascii_only?
    return if value.bytesize > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES || value.match?(CONTROL_PATTERN)

    value.encode(Encoding::UTF_8).unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip.presence
  end

  def normalized_bounds(polygon, page)
    width = page["width"]
    height = page["height"]
    return unless positive_dimension?(width) && positive_dimension?(height)
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |coordinate| finite_coordinate?(coordinate) }

    points = polygon.each_slice(2).to_a
    return unless points.all? { |x, y| x.between?(0, width) && y.between?(0, height) }
    return unless convex_polygon?(points)

    left, right = points.map(&:first).minmax.map { |x| (x.fdiv(width) * COORDINATE_SCALE).round }
    top, bottom = points.map(&:last).minmax.map { |y| (y.fdiv(height) * COORDINATE_SCALE).round }
    return unless right > left && bottom > top

    # 一部の文字列候補でも行全体の矩形を保持し、文字ごとの位置を推定しない。
    { left:, top:, width: right - left, height: bottom - top }
  end

  def positive_dimension?(value)
    finite_coordinate?(value) && value.positive?
  end

  def finite_coordinate?(value)
    (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.between?(0, MAX_PAGE_DIMENSION)
  end

  def convex_polygon?(points)
    crosses = points.each_index.map do |index|
      x1, y1 = points[index]
      x2, y2 = points[(index + 1) % points.size]
      x3, y3 = points[(index + 2) % points.size]
      (x2 - x1) * (y3 - y2) - (y2 - y1) * (x3 - x2)
    end
    crosses.all?(&:positive?) || crosses.all?(&:negative?)
  end
end
