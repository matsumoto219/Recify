class Ocr::ResponseParser::ReferencePricingLineGroupExtractor
  MAX_PAGES = 1
  MAX_LINES = 150
  MAX_WORDS = 4_800
  MAX_ITEMS = 100
  MAX_CONTENT_BYTES = 76_950
  MAX_LINE_CONTENT_BYTES = 512
  MAX_WORD_CONTENT_BYTES = 64
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  MAX_SUMMARY_TOTAL_AMOUNT = 999_999_999_999
  MAX_PAGE_DIMENSION = 10_000
  MAX_ITEM_FIELD_NODES = 512
  MAX_ITEM_FIELD_ENTRIES = 100
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  VALIDATION_CONTRACT_VERSION = "azure_line_group_v1"
  DESTINATION_CONTRACT_VERSION = "azure_line_group_destination_v1"
  DESTINATION_KIND = "reference_line_prefix"
  MIN_DESTINATION_NAME_GRAPHEMES = 3
  MAX_DESTINATION_NAME_GRAPHEMES = 24
  MAX_DESTINATION_NAME_BYTES = 96
  MAX_DESTINATION_WORDS = 8
  MIN_DESTINATION_WORD_VERTICAL_OVERLAP_RATIO = Rational(17, 18)
  MAX_DESTINATION_WORD_TOP_DELTA_RATIO = Rational(1, 18)
  MIN_DESTINATION_WORD_GAP_RATIO = Rational(1, 6)
  MAX_DESTINATION_WORD_GAP_RATIO = Rational(3, 8)
  DESTINATION_TAX_WORD_COUNT = 2
  MIN_DESTINATION_TAX_WORD_GAP_RATIO = Rational(2, 9)
  MAX_DESTINATION_TAX_WORD_GAP_RATIO = Rational(7, 16)
  MIN_DESTINATION_TAX_HORIZONTAL_GAP_RATIO = Rational(1, 3)
  MAX_DESTINATION_TAX_HORIZONTAL_GAP_RATIO = Rational(1, 2)
  MAX_VERTICAL_GAP_RATIO = Rational(7, 16)
  MAX_WORD_LINE_OVERHANG = 1

  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  DASH_RANGE_PATTERN = /[0-9０-９][^\n]{0,12}[ \t]*[-‐‑‒–—―−][ \t]*[0-9０-９]/u.freeze
  NESTED_PACKAGE_PATTERN = /(?:[0-9０-９][^\n]{0,24}[x×][ \t]*[0-9０-９]|[x×][ \t]*[0-9０-９])/i.freeze
  SIGNED_ADJUSTMENT_AMOUNT_PATTERN =
    /(?<![A-Za-z0-9])(?:[▲△]|[-−+])[ \t]*(?:[¥￥$€£][ \t]*)?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?(?:[ \t]*円)?(?![A-Za-z0-9.])/.freeze
  BARE_ADJACENT_AMOUNT_PATTERN =
    /(?:\A|[ \t])(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+(?:\.[0-9]+)?)(?=\z|[ \t])/.freeze
  REFERENCE_EXPRESSION_MARKER_PATTERN =
    %r{(?:[¥￥$€£@][ \t]*[0-9]|(?:USD|EUR|GBP|JPY)[ \t]*[0-9]|[0-9][ \t]*円)[^\n]{0,24}[/／][ \t]*(?:[0-9]|[\p{L}])}iu.freeze
  MONETARY_NEIGHBOR_PATTERN = /(?:[¥￥$€£][ \t]*[0-9０-９]|[0-9０-９][ \t]*円)/u.freeze
  STRUCTURED_ITEM_VALUE_KEYS = %w[
    content
    valueCurrency
    valueNumber
    valueString
  ].freeze

  def self.call(analyze_result:, profile:, projection: nil)
    new(analyze_result:, profile:, projection:).call
  end

  def initialize(analyze_result:, profile:, projection: nil)
    @analyze_result = analyze_result
    @profile = profile
    @projection = projection || ->(**attributes) {
      ReceiptAmountService.reference_item_extension_projection(**attributes)
    }
  end

  def call
    return [] unless analyze_result.is_a?(Hash)
    return [] unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return [] unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    return [] if mapper.nil?

    content = bounded_text(analyze_result["content"], max_bytes: MAX_CONTENT_BYTES, allow_newlines: true)
    return [] if content.nil?

    pages = analyze_result["pages"]
    return [] unless pages.is_a?(Array) && pages.size == 1 && pages.size <= MAX_PAGES

    page = pages.sole
    lines = validated_lines(page, content:, mapper:)
    return [] if lines.nil?
    words = validated_words(page, lines:, content:, mapper:)
    return [] if words.nil?
    return [] unless lines.count { |line| purchased_quantity_line?(line[:content]) } == 1
    return [] unless lines.sum { |line| reference_expression_marker_count(line[:content]) } == 1

    candidates = []
    lines.each_cons(2).with_index do |(reference_line, purchased_line), reference_line_index|
      candidate = candidate_for_pair(
        reference_line:,
        purchased_line:,
        page_index: 0,
        reference_line_index:,
        content:,
        mapper:,
        lines:,
        words:
      )
      next if candidate.nil?

      candidates << candidate
      return [] if candidates.many?
    end

    candidates
  rescue EncodingError, ArgumentError, KeyError, TypeError
    []
  end

  private

  attr_reader :analyze_result, :profile, :projection

  def validated_lines(page, content:, mapper:)
    return unless page.is_a?(Hash)
    return unless page["unit"] == "pixel"

    page_width = finite_positive_number(page["width"])
    page_height = finite_positive_number(page["height"])
    return if page_width.nil? || page_height.nil?

    raw_lines = page["lines"]
    return unless raw_lines.is_a?(Array) && raw_lines.size.between?(2, MAX_LINES)

    lines = raw_lines.filter_map.with_index do |line, line_index|
      validated_layout_entry(
        line,
        content:,
        mapper:,
        page_width:,
        page_height:,
        max_content_bytes: MAX_LINE_CONTENT_BYTES,
        line_index:
      )
    end
    return unless lines.size == raw_lines.size
    return unless lines.each_cons(2).all? do |left, right|
      left[:span_end] < right[:span_start]
    end

    lines
  end

  def validated_words(page, lines:, content:, mapper:)
    page_width = finite_positive_number(page["width"])
    page_height = finite_positive_number(page["height"])
    words = page["words"]
    return unless words.is_a?(Array) && words.size.between?(1, MAX_WORDS)

    validated_words = words.filter_map.with_index do |word, word_index|
      validated_layout_entry(
        word,
        content:,
        mapper:,
        page_width:,
        page_height:,
        max_content_bytes: MAX_WORD_CONTENT_BYTES,
        word_index:,
        word: true
      )
    end
    return unless validated_words.size == words.size
    return unless validated_words.each_cons(2).all? do |left, right|
      left[:span_end] <= right[:span_start]
    end

    line_index = 0
    valid_associations = validated_words.all? do |word|
      while line_index < lines.size && word[:span_start] >= lines.fetch(line_index)[:span_end]
        line_index += 1
      end
      break false if line_index >= lines.size

      line = lines.fetch(line_index)
      range_within?(word[:span_start], word[:span_end], line[:span_start], line[:span_end]) &&
        word_within_line?(word[:bounds], line[:bounds])
    end
    valid_associations ? validated_words : nil
  end

  def validated_layout_entry(
    entry,
    content:,
    mapper:,
    page_width:,
    page_height:,
    max_content_bytes:,
    line_index: nil,
    word_index: nil,
    word: false
  )
    return unless entry.is_a?(Hash)

    entry_content = bounded_text(entry["content"], max_bytes: max_content_bytes, allow_newlines: false)
    return if entry_content.blank?

    span = word ? bounded_span(entry["span"]) : single_span(entry)
    return if span.nil?
    return unless mapper.length(entry_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == entry_content

    bounds = polygon_bounds(
      entry["polygon"],
      page_width:,
      page_height:
    )
    return if bounds.nil?

    {
      content: entry_content,
      span_start: span.fetch(:offset),
      span_end: span.fetch(:offset) + span.fetch(:length),
      bounds:,
      line_index:,
      word_index:
    }
  end

  def candidate_for_pair(
    reference_line:,
    purchased_line:,
    page_index:,
    reference_line_index:,
    content:,
    mapper:,
    lines:,
    words:
  )
    return unless strict_pair_layout?(reference_line, purchased_line, content:, mapper:)
    return unless purchased_quantity_line?(purchased_line[:content])
    return if package_or_uncertain?(reference_line[:content]) || package_or_uncertain?(purchased_line[:content])
    return if discount_adjustment_text?(reference_line[:content]) || discount_adjustment_text?(purchased_line[:content])
    return if nearby_conflict?(lines, reference_line_index:)
    return if block_overlaps_existing_item?(
      content:,
      mapper:,
      block_start: reference_line[:span_start],
      block_end: purchased_line[:span_end]
    )

    pseudo_item, field_bases = pseudo_item_for(reference_line, purchased_line)
    validated_candidates = Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items: [ pseudo_item ],
      profile:,
      projection:,
      allow_separated_tax_label: true
    )
    return unless validated_candidates.one?

    candidate = validated_candidates.sole
    return unless candidate[:validation_state] == "valid"
    return unless candidate[:printed_line_total].nil?
    return unless decimal_measurement_candidate?(candidate)

    purchased_line_index = reference_line_index + 1
    typed = typed_candidate(
      candidate,
      mapper:,
      reference_line:,
      purchased_line:,
      page_index:,
      reference_line_index:,
      purchased_line_index:,
      field_bases:
    )
    return if typed.nil?
    return unless strict_reference_line_evidence_coverage?(
      typed,
      reference_line:,
      content:,
      mapper:
    )
    return unless component_evidence_covered_by_words?(typed, words:, content:, mapper:)

    destination_item_identity = destination_item_identity(
      typed,
      reference_line:,
      purchased_line:,
      page_index:,
      reference_line_index:,
      purchased_line_index:,
      lines:,
      words:,
      content:,
      mapper:
    )
    typed[:destination_item_identity] = destination_item_identity if destination_item_identity

    summary = summary_total_corroboration(
      typed,
      lines:,
      content:,
      mapper:,
      block_start: reference_line[:span_start],
      block_end: purchased_line[:span_end]
    )
    typed[:summary_total_corroboration] = summary if summary
    typed
  rescue NoMethodError
    nil
  end

  def strict_pair_layout?(reference_line, purchased_line, content:, mapper:)
    return false unless purchased_line[:span_start] == reference_line[:span_end] + 1
    return false unless mapper.slice(content, offset: reference_line[:span_end], length: 1) == "\n"

    reference_bounds = reference_line[:bounds]
    purchased_bounds = purchased_line[:bounds]
    return false unless reference_bounds[:left] == purchased_bounds[:left]
    return false unless horizontally_contained?(reference_bounds, purchased_bounds)
    return false unless reference_bounds[:bottom] <= purchased_bounds[:top]

    gap = purchased_bounds[:top] - reference_bounds[:bottom]
    max_height = [ reference_bounds[:height], purchased_bounds[:height] ].max
    return false unless max_height.positive?

    gap / max_height <= MAX_VERTICAL_GAP_RATIO
  end

  def horizontally_contained?(left, right)
    (left[:left] <= right[:left] && left[:right] >= right[:right]) ||
      (right[:left] <= left[:left] && right[:right] >= left[:right])
  end

  def pseudo_item_for(reference_line, purchased_line)
    utf16 = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: "utf16CodeUnit")
    reference_length = utf16.length(reference_line[:content])
    purchased_length = utf16.length(purchased_line[:content])
    purchased_offset = reference_length + 1
    item_content = "#{reference_line[:content]}\n#{purchased_line[:content]}"

    [
      {
        "content" => item_content,
        "spans" => [ { "offset" => 0, "length" => utf16.length(item_content) } ],
        "valueObject" => {
          "Price" => {
            "content" => reference_line[:content],
            "spans" => [ { "offset" => 0, "length" => reference_length } ]
          },
          "Quantity" => {
            "content" => purchased_line[:content],
            "spans" => [ { "offset" => purchased_offset, "length" => purchased_length } ]
          }
        }
      },
      {
        price: 0,
        quantity: purchased_offset
      }
    ]
  end

  def typed_candidate(
    candidate,
    mapper:,
    reference_line:,
    purchased_line:,
    page_index:,
    reference_line_index:,
    purchased_line_index:,
    field_bases:
  )
    typed = candidate.deep_dup
    typed.delete(:item_index)
    typed[:candidate_id] = "azure_line_group_p#{page_index}_l#{reference_line_index}_l#{purchased_line_index}_reference_pricing"
    typed[:source_kind] = "azure_line_group"
    typed[:page_index] = page_index
    typed[:reference_line_index] = reference_line_index
    typed[:purchased_quantity_line_index] = purchased_line_index
    typed[:string_index_type] = mapper.index_type
    typed[:provider_model_id] = SUPPORTED_MODEL_ID
    typed[:provider_api_version] = SUPPORTED_API_VERSION
    typed[:validation_contract_version] = VALIDATION_CONTRACT_VERSION
    typed[:block_provider_span_start] = reference_line[:span_start]
    typed[:block_provider_span_end] = purchased_line[:span_end]

    mappings = {
      reference_price: reference_line,
      reference_quantity: reference_line,
      purchased_quantity: purchased_line
    }
    mappings.each do |component_name, line|
      component = typed[component_name]
      return if component.nil?

      component[:evidence] = typed_evidence(
        component[:evidence],
        line:,
        mapper:,
        page_index:,
        line_index: line[:line_index],
        field_bases:
      )
      return if component[:evidence].nil?
    end

    typed[:tax_inclusion_evidence] = typed_evidence(
      typed[:tax_inclusion_evidence],
      line: reference_line,
      mapper:,
      page_index:,
      line_index: reference_line_index,
      field_bases:
    )
    return if typed[:tax_inclusion_evidence].nil?

    typed
  end

  def destination_item_identity(
    candidate,
    reference_line:,
    purchased_line:,
    page_index:,
    reference_line_index:,
    purchased_line_index:,
    lines:,
    words:,
    content:,
    mapper:
  )
    return unless page_index.zero?
    return unless reference_line_index == reference_line[:line_index]
    return unless purchased_line_index == purchased_line[:line_index]

    tax_evidence = candidate[:tax_inclusion_evidence]
    return unless tax_evidence.is_a?(Hash)

    line_start = reference_line[:span_start]
    tax_start = tax_evidence[:provider_span_start]
    tax_end = tax_evidence[:provider_span_end]
    return unless [ line_start, tax_start, tax_end ].all?(Integer)
    return unless line_start < tax_start && tax_start < tax_end

    prefix = mapper.slice(
      reference_line[:content],
      offset: 0,
      length: tax_start - line_start
    )
    return unless prefix.is_a?(String)

    match = prefix.match(/\A(?<name>[^\p{Zs}\t]+)(?<separator>[\p{Zs}])\z/u)
    return if match.nil?

    name = match[:name]
    return unless name.unicode_normalize(:nfkc) == name
    return unless name.bytesize <= MAX_DESTINATION_NAME_BYTES

    grapheme_length = name.scan(/\X/).size
    return unless grapheme_length.between?(MIN_DESTINATION_NAME_GRAPHEMES, MAX_DESTINATION_NAME_GRAPHEMES)
    return unless name.match?(profile.ocr_reference_pricing_line_group_identifier_pattern)
    return unless name.match?(/[\p{L}\p{N}]\z/u)
    return if destination_identifier_conflict?(name)
    return unless mapper.length(match[:separator]) == 1

    name_span = mapper.span_for_bytes(
      reference_line[:content],
      byte_offset: 0,
      byte_length: name.bytesize
    )
    return if name_span.nil?

    name_start = line_start + name_span.fetch(:offset)
    name_end = name_start + name_span.fetch(:length)
    return unless name_start == line_start
    return unless name_end + 1 == tax_start
    return unless unique_destination_name?(name, lines:)
    return unless provider_range_covered_by_words?(name_start, name_end, words:, content:, mapper:)
    destination_word_evidence = destination_word_evidence(
      name_start:,
      name_end:,
      tax_start:,
      tax_end:,
      page_index:,
      words:
    )
    return if destination_word_evidence.nil?
    return if destination_conflicts_with_non_item_fields?(
      name:,
      name_start:,
      name_end:
    )

    {
      contract_version: DESTINATION_CONTRACT_VERSION,
      kind: DESTINATION_KIND,
      identity: "azure_line_group_destination_p#{page_index}_name_l#{reference_line_index}_" \
        "s#{name_start}_e#{name_end}_ref_l#{reference_line_index}_qty_l#{purchased_line_index}",
      page_index:,
      name_line_index: reference_line_index,
      reference_line_index:,
      purchased_quantity_line_index: purchased_line_index,
      normalized_name_grapheme_length: grapheme_length,
      evidence: {
        source_provider: "azure_line_group",
        source_field_path: "pages[#{page_index}].lines[#{reference_line_index}]",
        page_index:,
        line_index: reference_line_index,
        string_index_type: mapper.index_type,
        provider_span_start: name_start,
        provider_span_end: name_end,
        word_spans: destination_word_evidence.fetch(:name_word_spans),
        tax_word_spans: destination_word_evidence.fetch(:tax_word_spans)
      }
    }
  rescue EncodingError, ArgumentError, KeyError, TypeError
    nil
  end

  def unique_destination_name?(name, lines:)
    occurrence_count = Array(lines).sum do |line|
      line[:content].to_s.scan(Regexp.new(Regexp.escape(name))).size
    end

    occurrence_count == 1
  rescue EncodingError, ArgumentError, TypeError
    false
  end

  def destination_identifier_conflict?(name)
    normalized = name.unicode_normalize(:nfkc)
    [
      profile.ocr_reference_pricing_line_group_identifier_conflict_pattern,
      profile.ocr_reference_pricing_line_group_destination_conflict_pattern,
      profile.ocr_reference_pricing_line_group_summary_context_pattern,
      profile.ocr_merchant_anchor_pattern,
      profile.ocr_payment_anchor_pattern,
      profile.ocr_adjustment_discount_label_pattern,
      profile.ocr_adjustment_surcharge_label_pattern,
      profile.ocr_adjustment_excluded_line_pattern,
      profile.ocr_datetime_anchor_pattern
    ].any? { |pattern| normalized.match?(pattern) }
  rescue EncodingError, ArgumentError, NoMethodError
    true
  end

  def destination_word_evidence(name_start:, name_end:, tax_start:, tax_end:, page_index:, words:)
    name_words = words.select do |word|
      ranges_overlap?(word[:span_start], word[:span_end], name_start, name_end)
    end
    tax_words = words.select do |word|
      ranges_overlap?(word[:span_start], word[:span_end], tax_start, tax_end)
    end
    return if name_words.empty? || tax_words.size != DESTINATION_TAX_WORD_COUNT
    return if name_words.size > MAX_DESTINATION_WORDS
    return unless exact_word_span_coverage?(name_words, range_start: name_start, range_end: name_end)
    return unless exact_word_span_coverage?(tax_words, range_start: tax_start, range_end: tax_end)
    return unless destination_word_layout_consistent?(name_words:, tax_words:)

    {
      name_word_spans: structural_word_evidence(name_words, page_index:),
      tax_word_spans: structural_word_evidence(tax_words, page_index:)
    }
  rescue ArgumentError, NoMethodError, TypeError
    nil
  end

  def exact_word_span_coverage?(words, range_start:, range_end:)
    return false if words.empty?
    return false unless words.first[:span_start] == range_start && words.last[:span_end] == range_end

    words.each_cons(2).all? { |left, right| left[:span_end] == right[:span_start] }
  end

  def structural_word_evidence(words, page_index:)
    words.map do |word|
      {
        source_field_path: "pages[#{page_index}].words[#{word.fetch(:word_index)}]",
        word_index: word.fetch(:word_index),
        provider_span_start: word.fetch(:span_start),
        provider_span_end: word.fetch(:span_end)
      }
    end
  end

  def destination_word_layout_consistent?(name_words:, tax_words:)
    name_bounds = aggregate_word_bounds(name_words)
    tax_bounds = aggregate_word_bounds(tax_words)
    return false if name_bounds.nil? || tax_bounds.nil?
    return false unless name_bounds.values_at(:top, :bottom) == tax_bounds.values_at(:top, :bottom)

    height = name_bounds.fetch(:bottom) - name_bounds.fetch(:top)
    return false unless height.positive?
    return false unless word_sequence_layout_consistent?(
      name_words,
      aggregate_bounds: tax_bounds,
      height:,
      min_gap_ratio: MIN_DESTINATION_WORD_GAP_RATIO,
      max_gap_ratio: MAX_DESTINATION_WORD_GAP_RATIO
    )
    return false unless word_sequence_layout_consistent?(
      tax_words,
      aggregate_bounds: tax_bounds,
      height:,
      min_gap_ratio: MIN_DESTINATION_TAX_WORD_GAP_RATIO,
      max_gap_ratio: MAX_DESTINATION_TAX_WORD_GAP_RATIO
    )

    horizontal_gap_ratio = (tax_bounds.fetch(:left) - name_bounds.fetch(:right)) / height
    horizontal_gap_ratio.between?(
      MIN_DESTINATION_TAX_HORIZONTAL_GAP_RATIO,
      MAX_DESTINATION_TAX_HORIZONTAL_GAP_RATIO
    )
  rescue ArgumentError, KeyError, NoMethodError, TypeError, ZeroDivisionError
    false
  end

  def word_sequence_layout_consistent?(words, aggregate_bounds:, height:, min_gap_ratio:, max_gap_ratio:)
    return false unless words.all? do |word|
      bounds = word.fetch(:bounds)
      overlap = [ bounds.fetch(:bottom), aggregate_bounds.fetch(:bottom) ].min -
        [ bounds.fetch(:top), aggregate_bounds.fetch(:top) ].max
      overlap / height >= MIN_DESTINATION_WORD_VERTICAL_OVERLAP_RATIO &&
        (bounds.fetch(:top) - aggregate_bounds.fetch(:top)).abs / height <=
          MAX_DESTINATION_WORD_TOP_DELTA_RATIO &&
        bounds.fetch(:bottom) == aggregate_bounds.fetch(:bottom)
    end

    words.each_cons(2).all? do |left_word, right_word|
      gap_ratio = (
        right_word.dig(:bounds, :left) - left_word.dig(:bounds, :right)
      ) / height
      gap_ratio.between?(min_gap_ratio, max_gap_ratio)
    end
  end

  def aggregate_word_bounds(words)
    bounds = words.map { |word| word[:bounds] }
    return if bounds.empty? || bounds.any?(&:nil?)

    {
      left: bounds.map { |value| value.fetch(:left) }.min,
      right: bounds.map { |value| value.fetch(:right) }.max,
      top: bounds.map { |value| value.fetch(:top) }.min,
      bottom: bounds.map { |value| value.fetch(:bottom) }.max
    }
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  def destination_conflicts_with_non_item_fields?(name:, name_start:, name_end:)
    fields = analyze_result.dig("documents", 0, "fields")
    return true unless fields.is_a?(Hash)

    stack = fields.except("Items").values
    return true unless stack.all?(Hash)
    visited_nodes = 0
    until stack.empty?
      node = stack.pop
      visited_nodes += 1
      return true if visited_nodes > MAX_ITEM_FIELD_NODES

      case node
      when Hash
        return true if node.size > MAX_ITEM_FIELD_ENTRIES

        %w[content valueString].each do |text_key|
          next unless node.key?(text_key)
          next if node[text_key].nil?

          field_text = bounded_text(node[text_key], max_bytes: MAX_LINE_CONTENT_BYTES, allow_newlines: true)
          return true if field_text.nil?
          return true if field_text.unicode_normalize(:nfkc).include?(name)
        end

        spans = node["spans"]
        if node.key?("spans") && !spans.nil?
          return true unless spans.is_a?(Array) && spans.size <= MAX_ITEM_FIELD_ENTRIES

          spans.each do |span|
            bounded = bounded_span(span)
            return true if bounded.nil?

            span_start = bounded.fetch(:offset)
            span_end = span_start + bounded.fetch(:length)
            return true if ranges_overlap?(span_start, span_end, name_start, name_end)
          end
        end

        children = node.filter_map do |key, value|
          next if %w[spans polygon].include?(key)
          next unless value.is_a?(Hash) || value.is_a?(Array)
          return true if value.is_a?(Array) && value.any? do |entry|
            !entry.is_a?(Hash) && !entry.is_a?(Array)
          end

          value
        end
        return true if stack.size + children.size + visited_nodes > MAX_ITEM_FIELD_NODES

        stack.concat(children)
      when Array
        return true if node.size > MAX_ITEM_FIELD_ENTRIES
        return true if stack.size + node.size + visited_nodes > MAX_ITEM_FIELD_NODES
        return true unless node.all? { |value| value.is_a?(Hash) || value.is_a?(Array) }

        stack.concat(node)
      else
        return true
      end
    end

    false
  rescue EncodingError, ArgumentError, KeyError, TypeError
    true
  end

  def typed_evidence(evidence, line:, mapper:, page_index:, line_index:, field_bases:)
    return unless evidence.is_a?(Hash)

    source_path = evidence[:source_field_path]
    field_key = if source_path&.end_with?(".Price")
      :price
    elsif source_path&.end_with?(".Quantity")
      :quantity
    end
    return if field_key.nil?

    internal_start = evidence[:provider_span_start]
    internal_end = evidence[:provider_span_end]
    return unless internal_start.is_a?(Integer) && internal_end.is_a?(Integer) && internal_end >= internal_start

    relative_start = internal_start - field_bases.fetch(field_key)
    relative_length = internal_end - internal_start
    utf16 = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: "utf16CodeUnit")
    byte_range = utf16.byte_range_for_span(
      line[:content],
      offset: relative_start,
      length: relative_length
    )
    return if byte_range.nil?

    provider_span = mapper.span_for_bytes(
      line[:content],
      byte_offset: byte_range.begin,
      byte_length: byte_range.size
    )
    return if provider_span.nil?

    {
      source_provider: "azure_line_group",
      source_field_path: "pages[#{page_index}].lines[#{line_index}]",
      page_index:,
      line_index:,
      string_index_type: mapper.index_type,
      provider_span_start: line[:span_start] + provider_span.fetch(:offset),
      provider_span_end: line[:span_start] + provider_span.fetch(:offset) + provider_span.fetch(:length)
    }
  end

  def summary_total_corroboration(candidate, lines:, content:, mapper:, block_start:, block_end:)
    documents = analyze_result["documents"]
    return unless documents.is_a?(Array) && documents.size == 1

    summary_lines = lines.reject do |line|
      ranges_overlap?(line[:span_start], line[:span_end], block_start, block_end)
    end.select do |line|
      line[:span_start] >= block_end &&
      line[:content].match?(profile.ocr_strict_receipt_summary_total_line_pattern)
    end
    return unless summary_lines.one?

    summary_line = summary_lines.sole
    amounts = summary_line[:content].scan(/[0-9０-９][0-9０-９,，]*/).filter_map do |value|
      ReceiptAmountService.parse_amount_or_nil(value)&.to_i
    end.uniq
    return unless amounts.one?

    summary_total = amounts.sole
    total_field = documents.sole.dig("fields", "Total")
    return unless summary_total_owned_by_line?(
      total_field,
      summary_line:,
      summary_total:,
      content:,
      mapper:,
      block_start:,
      block_end:
    )

    result = projection.call(
      reference_price_amount: candidate.dig(:reference_price, :amount),
      reference_quantity: candidate.dig(:reference_quantity, :amount),
      reference_unit_code: candidate.dig(:reference_quantity, :unit_code),
      purchased_quantity: candidate.dig(:purchased_quantity, :amount),
      purchased_unit_code: candidate.dig(:purchased_quantity, :unit_code)
    )
    exact_amount = result.fetch(:exact_amount).to_r

    {
      exact_amount: {
        numerator: exact_amount.numerator.to_s,
        denominator: exact_amount.denominator.to_s
      },
      projected_amount: Integer(result.fetch(:projected_amount)),
      summary_total: summary_total.to_s,
      rounding_matches: rounding_matches(exact_amount, summary_total)
    }
  rescue ReceiptAmountService::InvalidItemSourceError
    nil
  end

  def summary_total_owned_by_line?(
    total_field,
    summary_line:,
    summary_total:,
    content:,
    mapper:,
    block_start:,
    block_end:
  )
    return true if total_field.nil?
    return false unless total_field.is_a?(Hash)

    spans = total_field["spans"]
    return true if spans.nil?
    return false unless spans.is_a?(Array)
    return true if spans.empty?
    return false unless spans.size == 1

    field_content = bounded_text(total_field["content"], max_bytes: MAX_LINE_CONTENT_BYTES, allow_newlines: false)
    field_span = bounded_span(spans.sole)
    return false if field_content.nil? || field_span.nil?
    return false unless mapper.length(field_content) == field_span.fetch(:length)
    return false unless mapper.slice(
      content,
      offset: field_span.fetch(:offset),
      length: field_span.fetch(:length)
    ) == field_content

    field_start = field_span.fetch(:offset)
    field_end = field_start + field_span.fetch(:length)
    return true if range_within?(field_start, field_end, block_start, block_end)
    return false if ranges_overlap?(field_start, field_end, block_start, block_end)
    return false unless range_within?(
      field_start,
      field_end,
      summary_line[:span_start],
      summary_line[:span_end]
    )

    structured_total_amount(total_field, field_content) == summary_total
  end

  def rounding_matches(exact_amount, summary_total)
    {
      "floor" => exact_amount.floor,
      "half_up" => (exact_amount + Rational(1, 2)).floor,
      "ceil" => exact_amount.ceil
    }.filter_map { |name, amount| name if amount == summary_total }
  end

  def package_or_uncertain?(text)
    normalized = text.unicode_normalize(:nfkc)
    normalized.match?(profile.ocr_reference_pricing_line_group_package_or_uncertain_pattern) ||
      normalized.match?(NESTED_PACKAGE_PATTERN) ||
      normalized.match?(DASH_RANGE_PATTERN)
  rescue EncodingError, ArgumentError
    true
  end

  def purchased_quantity_line?(text)
    text.match?(profile.ocr_reference_pricing_line_group_purchased_quantity_line_pattern)
  end

  def reference_expression_marker_count(text)
    text.unicode_normalize(:nfkc).scan(REFERENCE_EXPRESSION_MARKER_PATTERN).size
  rescue EncodingError, ArgumentError
    MAX_LINES
  end

  def nearby_conflict?(lines, reference_line_index:)
    preceding = lines[reference_line_index - 1] if reference_line_index.positive?
    following = lines[reference_line_index + 2]

    return true if preceding && neighboring_line_conflict?(preceding[:content])
    return false if following.nil?
    return true if neighboring_line_conflict?(following[:content], allow_summary_total: true)

    false
  end

  def neighboring_line_conflict?(text, allow_summary_total: false)
    normalized = text.unicode_normalize(:nfkc)
    return false if allow_summary_total && normalized.match?(profile.ocr_strict_receipt_summary_total_line_pattern)
    return false if allow_summary_total && normalized.match?(profile.ocr_strict_receipt_subtotal_line_pattern)
    return true if normalized.match?(profile.ocr_reference_pricing_line_group_identifier_conflict_pattern) ||
      normalized.match?(profile.analysis_non_taxable_text_pattern) ||
      normalized.match?(profile.ocr_adjustment_discount_label_pattern) ||
      normalized.match?(profile.analysis_return_refund_kind_pattern) ||
      discount_adjustment_text?(normalized) || package_or_uncertain?(normalized) ||
      adjacent_measurement_quantity?(normalized) || purchased_quantity_line?(normalized) ||
      signed_adjustment_amount?(normalized) || bare_adjacent_amount?(normalized) ||
      reference_expression_marker_count(normalized).positive?

    normalized.match?(MONETARY_NEIGHBOR_PATTERN)
  rescue EncodingError, ArgumentError
    true
  end

  def decimal_measurement_candidate?(candidate)
    reference_unit = ReceiptQuantityUnit.unit_for(candidate.dig(:reference_quantity, :unit_code))
    purchased_unit = ReceiptQuantityUnit.unit_for(candidate.dig(:purchased_quantity, :unit_code))

    reference_unit&.kind == :decimal && purchased_unit&.kind == :decimal
  end

  def block_overlaps_existing_item?(content:, mapper:, block_start:, block_end:)
    documents = analyze_result["documents"]
    return true unless documents.is_a?(Array) && documents.size == 1

    document = documents.sole
    return true unless document.is_a?(Hash)

    fields = document["fields"]
    return true unless fields.is_a?(Hash)

    items_field = fields["Items"]
    return false if items_field.nil?
    return true unless items_field.is_a?(Hash)

    items = items_field["valueArray"]
    return true unless items.is_a?(Array) && items.size <= MAX_ITEMS

    items.any? do |item|
      return true unless item.is_a?(Hash)

      item_content = bounded_text(item["content"], max_bytes: MAX_LINE_CONTENT_BYTES * 8, allow_newlines: true)
      item_span = single_span(item)
      return true if item_content.blank? || item_span.nil?
      return true unless item_span.fetch(:length).positive?
      return true unless mapper.length(item_content) == item_span.fetch(:length)
      return true unless mapper.slice(
        content,
        offset: item_span.fetch(:offset),
        length: item_span.fetch(:length)
      ) == item_content

      parent_start = item_span.fetch(:offset)
      parent_end = parent_start + item_span.fetch(:length)
      return true unless structured_item_fields_owned_by_parent?(
        item["valueObject"],
        content:,
        mapper:,
        parent_start:,
        parent_end:,
        block_start:,
        block_end:
      )

      ranges_overlap?(
        parent_start,
        parent_end,
        block_start,
        block_end
      )
    end
  end

  def structured_item_fields_owned_by_parent?(
    value_object,
    content:,
    mapper:,
    parent_start:,
    parent_end:,
    block_start:,
    block_end:
  )
    return false unless value_object.is_a?(Hash)

    stack = [ value_object ]
    visited_nodes = 0
    until stack.empty?
      node = stack.pop
      visited_nodes += 1
      return false if visited_nodes > MAX_ITEM_FIELD_NODES

      case node
      when Hash
        return false if node.size > MAX_ITEM_FIELD_ENTRIES

        if node.key?("spans") || STRUCTURED_ITEM_VALUE_KEYS.any? { |key| node.key?(key) }
          field_content = bounded_text(node["content"], max_bytes: MAX_LINE_CONTENT_BYTES, allow_newlines: true)
          field_span = single_span(node)
          return false if field_content.blank? || field_span.nil?
          return false unless field_span.fetch(:length).positive?
          return false unless mapper.length(field_content) == field_span.fetch(:length)
          return false unless mapper.slice(
            content,
            offset: field_span.fetch(:offset),
            length: field_span.fetch(:length)
          ) == field_content

          field_start = field_span.fetch(:offset)
          field_end = field_start + field_span.fetch(:length)
          return false unless range_within?(field_start, field_end, parent_start, parent_end)
          return false if ranges_overlap?(field_start, field_end, block_start, block_end)
        end

        children = []
        node.each do |key, value|
          next if key == "spans"
          next unless value.is_a?(Hash) || value.is_a?(Array)

          children << value
        end
        return false if stack.size + children.size + visited_nodes > MAX_ITEM_FIELD_NODES

        stack.concat(children)
      when Array
        return false if node.size > MAX_ITEM_FIELD_ENTRIES
        return false if stack.size + node.size + visited_nodes > MAX_ITEM_FIELD_NODES

        node.each do |value|
          return false unless value.is_a?(Hash) || value.is_a?(Array)

          stack << value
        end
      else
        return false
      end
    end

    true
  rescue EncodingError, ArgumentError, KeyError, TypeError
    false
  end

  def structured_total_amount(field, field_content)
    currency = field["valueCurrency"]
    return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

    raw_amount = currency["amount"]
    return unless raw_amount.is_a?(Integer) || raw_amount.is_a?(Float)
    return if raw_amount.is_a?(Float) && !raw_amount.finite?
    return if raw_amount.negative? || raw_amount > MAX_SUMMARY_TOTAL_AMOUNT

    structured = BigDecimal(raw_amount.to_s)
    return unless structured.frac.zero?

    lexical = field_content.scan(/[0-9０-９][0-9０-９,，]*/).filter_map do |value|
      ReceiptAmountService.parse_amount_or_nil(value)&.to_i
    end.uniq
    return unless lexical.one? && structured == lexical.sole

    structured.to_i
  rescue ArgumentError, TypeError
    nil
  end

  def component_evidence_covered_by_words?(candidate, words:, content:, mapper:)
    evidence = %i[reference_price reference_quantity purchased_quantity].filter_map do |component|
      candidate.dig(component, :evidence)
    end
    evidence << candidate[:tax_inclusion_evidence]

    evidence.all? do |entry|
      provider_range_covered_by_words?(
        entry[:provider_span_start],
        entry[:provider_span_end],
        words:,
        content:,
        mapper:
      )
    end
  end

  def strict_reference_line_evidence_coverage?(candidate, reference_line:, content:, mapper:)
    tax_evidence = candidate[:tax_inclusion_evidence]
    price_evidence = candidate.dig(:reference_price, :evidence)
    quantity_evidence = candidate.dig(:reference_quantity, :evidence)
    return false unless [ tax_evidence, price_evidence, quantity_evidence ].all?(Hash)

    line_start = reference_line[:span_start]
    line_end = reference_line[:span_end]
    tax_start = tax_evidence[:provider_span_start]
    tax_end = tax_evidence[:provider_span_end]
    price_start = price_evidence[:provider_span_start]
    quantity_end = quantity_evidence[:provider_span_end]
    offsets = [ line_start, line_end, tax_start, tax_end, price_start, quantity_end ]
    return false unless offsets.all?(Integer)
    return false unless line_start <= tax_start && tax_start < tax_end
    return false unless tax_end <= price_start && price_start < quantity_end
    return false unless quantity_end <= line_end

    prefix = mapper.slice(content, offset: line_start, length: tax_start - line_start)
    middle = mapper.slice(content, offset: tax_end, length: price_start - tax_end)
    suffix = mapper.slice(content, offset: quantity_end, length: line_end - quantity_end)
    return false if prefix.nil? || middle.nil? || suffix.nil?

    return false unless strict_reference_prefix?(prefix)

    middle = middle.unicode_normalize(:nfkc)
    suffix = suffix.unicode_normalize(:nfkc)
    rate = "[0-9]{1,2}(?:\\.[0-9]+)?[ \\t]*%"
    rate_part = "(?:(?:#{rate})|(?:\\([ \\t]*#{rate}[ \\t]*\\)))?"
    currency = "(?:[¥￥@＠][ \\t]*)?"
    unwrapped_middle = Regexp.new("\\A[ \\t]*#{rate_part}[ \\t]*#{currency}\\z")
    wrapped_middle = Regexp.new("\\A[ \\t]*#{rate_part}[ \\t]*\\([ \\t]*#{currency}\\z")

    (middle.match?(unwrapped_middle) && suffix.match?(/\A[ \t]*\z/)) ||
      (middle.match?(wrapped_middle) && suffix.match?(/\A[ \t]*\)[ \t]*\z/))
  rescue EncodingError, ArgumentError, TypeError
    false
  end

  def strict_reference_prefix?(prefix)
    normalized = prefix.unicode_normalize(:nfkc).strip
    return true if normalized.empty?

    post_discount = profile.ocr_post_discount_price_basis_pattern
    exact_post_discount = Regexp.new("\\A(?:#{post_discount.source})\\z", post_discount.options)
    return true if normalized.match?(exact_post_discount)
    return false if normalized.match?(post_discount)
    return false if normalized.scan(/\X/).size > 24
    return false unless normalized.match?(profile.ocr_reference_pricing_line_group_identifier_pattern)
    return false if normalized.match?(profile.ocr_reference_pricing_line_group_identifier_conflict_pattern)
    return false if normalized.match?(profile.analysis_non_taxable_text_pattern)
    return false if normalized.match?(profile.ocr_adjustment_discount_label_pattern)
    return false if package_or_uncertain?(normalized)
    return false if discount_adjustment_text?(normalized)
    return false if normalized.match?(identifier_measurement_quantity_pattern)
    return false if adjacent_measurement_quantity?(normalized)
    return false if normalized.match?(MONETARY_NEIGHBOR_PATTERN)
    return false if normalized.match?(profile.ocr_reference_pricing_line_group_summary_context_pattern)

    true
  rescue EncodingError, ArgumentError
    false
  end

  def provider_range_covered_by_words?(start_offset, end_offset, words:, content:, mapper:)
    return false unless start_offset.is_a?(Integer) && end_offset.is_a?(Integer)
    return false unless end_offset > start_offset

    overlapping_words = words.select do |word|
      ranges_overlap?(word[:span_start], word[:span_end], start_offset, end_offset)
    end
    return false if overlapping_words.empty?

    cursor = start_offset
    overlapping_words.each do |word|
      if word[:span_start] > cursor
        gap_end = [ word[:span_start], end_offset ].min
        return false unless provider_whitespace?(content, mapper:, start_offset: cursor, end_offset: gap_end)
      end
      cursor = [ cursor, word[:span_end] ].max
      return true if cursor >= end_offset
    end

    cursor >= end_offset || provider_whitespace?(
      content,
      mapper:,
      start_offset: cursor,
      end_offset:
    )
  end

  def provider_whitespace?(content, mapper:, start_offset:, end_offset:)
    return true if end_offset <= start_offset

    mapper.slice(content, offset: start_offset, length: end_offset - start_offset)&.match?(/\A[ \t]*\z/)
  end

  def word_within_line?(word_bounds, line_bounds)
    bounding_box_within_line = word_bounds[:left] >= line_bounds[:left] - MAX_WORD_LINE_OVERHANG &&
      word_bounds[:right] <= line_bounds[:right] + MAX_WORD_LINE_OVERHANG &&
      word_bounds[:top] >= line_bounds[:top] - MAX_WORD_LINE_OVERHANG &&
      word_bounds[:bottom] <= line_bounds[:bottom] + MAX_WORD_LINE_OVERHANG
    return false unless bounding_box_within_line

    word_bounds.fetch(:points).all? do |point|
      point_within_convex_polygon?(point, line_bounds.fetch(:points))
    end
  end

  def point_within_convex_polygon?(point, polygon)
    polygon.each_index.all? do |index|
      first = polygon.fetch(index)
      second = polygon.fetch((index + 1) % polygon.size)
      delta_x = second[0] - first[0]
      delta_y = second[1] - first[1]
      cross_product = (delta_x * (point[1] - first[1])) - (delta_y * (point[0] - first[0]))
      next true if cross_product >= 0

      (cross_product * cross_product) <=
        (MAX_WORD_LINE_OVERHANG**2 * ((delta_x * delta_x) + (delta_y * delta_y)))
    end
  end

  def discount_adjustment_text?(text)
    normalized = text.unicode_normalize(:nfkc)
    return true if normalized.match?(profile.ocr_reference_pricing_line_group_discount_conflict_pattern)
    return false unless normalized.match?(profile.ocr_item_discount_keyword_pattern)

    residual = normalized.gsub(profile.ocr_post_discount_price_basis_pattern, " ")
    residual.match?(profile.ocr_item_discount_keyword_pattern)
  rescue EncodingError, ArgumentError
    true
  end

  def signed_adjustment_amount?(text)
    text.unicode_normalize(:nfkc).match?(SIGNED_ADJUSTMENT_AMOUNT_PATTERN)
  rescue EncodingError, ArgumentError
    true
  end

  def bare_adjacent_amount?(text)
    text.unicode_normalize(:nfkc).match?(BARE_ADJACENT_AMOUNT_PATTERN)
  rescue EncodingError, ArgumentError
    true
  end

  def adjacent_measurement_quantity?(text)
    normalized = text.unicode_normalize(:nfkc)
    normalized.match?(adjacent_measurement_quantity_pattern)
  rescue EncodingError, ArgumentError
    true
  end

  def adjacent_measurement_quantity_pattern
    @adjacent_measurement_quantity_pattern ||= begin
      aliases = profile.quantity_unit_aliases.keys.map(&:to_s).reject(&:empty?).uniq
        .sort_by { |value| -value.length }
      return /(?!)/ if aliases.empty?

      latin_aliases, other_aliases = aliases.partition { |value| value.match?(/\A[A-Za-z]+\z/) }
      unit_sources = []
      unit_sources << "(?:#{Regexp.union(latin_aliases).source})(?![A-Za-z])" if latin_aliases.any?
      unit_sources << "(?:#{Regexp.union(other_aliases).source})" if other_aliases.any?

      Regexp.new(
        "(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)[ \\t]*(?:#{unit_sources.join("|")})",
        Regexp::IGNORECASE | Regexp::FIXEDENCODING
      )
    end
  end

  def identifier_measurement_quantity_pattern
    @identifier_measurement_quantity_pattern ||= begin
      aliases = profile.quantity_unit_aliases.filter_map do |unit_alias, unit_code|
        unit = ReceiptQuantityUnit.unit_for(unit_code)
        unit_alias.to_s if unit&.kind == :decimal
      end.reject(&:empty?).uniq.sort_by { |value| -value.length }
      return /(?!)/ if aliases.empty?

      Regexp.new(
        "(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)[ \\t]*(?:#{Regexp.union(aliases).source})",
        Regexp::IGNORECASE | Regexp::FIXEDENCODING
      )
    end
  end

  def bounded_text(value, max_bytes:, allow_newlines:)
    return unless value.is_a?(String)
    return if value.bytesize > max_bytes
    return unless value.valid_encoding?
    return if value.match?(CONTROL_CHARACTER_PATTERN)
    return if !allow_newlines && value.match?(/[\n\r\u0085\u2028\u2029]/)

    value.encode(Encoding::UTF_8).freeze
  rescue EncodingError, ArgumentError
    nil
  end

  def single_span(container)
    spans = container["spans"]
    return unless spans.is_a?(Array) && spans.size == 1

    bounded_span(spans.sole)
  end

  def bounded_span(value)
    return unless value.is_a?(Hash)

    offset = value["offset"]
    length = value["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer)
    return if offset.negative? || length.negative?
    return if offset > MAX_PROVIDER_SPAN_VALUE || length > MAX_PROVIDER_SPAN_VALUE
    return if offset + length > MAX_PROVIDER_SPAN_VALUE

    { offset:, length: }
  end

  def polygon_bounds(value, page_width:, page_height:)
    return unless value.is_a?(Array) && value.size == 8

    coordinates = value.map { |coordinate| finite_number(coordinate) }
    return if coordinates.any?(&:nil?)

    points = coordinates.each_slice(2).map { |x, y| [ x, y ] }
    return unless points.all? do |x, y|
      x >= 0 && x <= page_width && y >= 0 && y <= page_height
    end

    cross_products = points.each_index.map do |index|
      first = points.fetch(index)
      second = points.fetch((index + 1) % points.size)
      third = points.fetch((index + 2) % points.size)
      ((second[0] - first[0]) * (third[1] - second[1])) -
        ((second[1] - first[1]) * (third[0] - second[0]))
    end
    return unless cross_products.all?(&:positive?)

    left, right = points.map(&:first).minmax
    top, bottom = points.map(&:last).minmax
    return unless right > left && bottom > top

    { left:, right:, top:, bottom:, height: bottom - top, points: points.map(&:freeze).freeze }
  end

  def finite_positive_number(value)
    number = finite_number(value)
    number if number&.positive?
  end

  def finite_number(value)
    case value
    when Integer
      return if value < -MAX_PAGE_DIMENSION || value > MAX_PAGE_DIMENSION

      value.to_r
    when Float
      return unless value.finite? && value.between?(-MAX_PAGE_DIMENSION, MAX_PAGE_DIMENSION)

      value.to_r
    when BigDecimal
      return unless value.finite? && value.between?(-MAX_PAGE_DIMENSION, MAX_PAGE_DIMENSION)

      value.to_r
    end
  rescue ArgumentError, FloatDomainError
    nil
  end

  def ranges_overlap?(left_start, left_end, right_start, right_end)
    left_start < right_end && right_start < left_end
  end

  def range_within?(inner_start, inner_end, outer_start, outer_end)
    inner_start >= outer_start && inner_end >= inner_start && inner_end <= outer_end
  end
end
