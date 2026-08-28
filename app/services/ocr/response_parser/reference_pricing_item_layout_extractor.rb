class Ocr::ResponseParser::ReferencePricingItemLayoutExtractor
  MAX_PAGES = 1
  MAX_LINES = 150
  MAX_WORDS = 4_800
  MAX_ITEMS = 100
  MAX_CONTENT_BYTES = Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  MAX_LINE_CONTENT_BYTES = 512
  MAX_WORD_CONTENT_BYTES = 64
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  MAX_PAGE_DIMENSION = 10_000
  MAX_ITEM_FIELD_BYTES = 4_096
  MAX_PRODUCT_NAME_BYTES = 96
  MAX_PRODUCT_NAME_GRAPHEMES = 32
  MAX_PRODUCT_WORDS = 8
  MAX_DECIMAL_TOKEN_BYTES = 32
  MAX_VERTICAL_GAP_RATIO = Rational(1, 2)
  MIN_COLUMN_VERTICAL_OVERLAP_RATIO = Rational(7, 8)
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  SOURCE_KIND = "azure_item_layout"
  VALIDATION_CONTRACT_VERSION = "azure_item_layout_v1"
  CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
  DECIMAL_PATTERN = /\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/.freeze
  INTEGER_AMOUNT_PATTERN = /\A(?:0|[1-9][0-9]*)\z/.freeze
  COLUMN_CELL_PATTERN = /\A[ \t]*(?<amount>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)[ \t]*\z/.freeze
  PRODUCT_NAME_TOKEN_PATTERN = /[\p{L}\p{N}]/u.freeze

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
    return [] unless provider_context_valid?

    raw_blocks = ordinary_blocks + quantity_before_reference_blocks + column_blocks
    descriptors = raw_blocks.filter_map { |block| descriptor_for(block) }
    return [] unless descriptors.map { |descriptor| descriptor[:candidate_id] }.uniq.size == descriptors.size
    return [] unless descriptors.map { |descriptor| descriptor[:item_identity] }.uniq.size == descriptors.size
    return [] if descriptors.combination(2).any? do |left, right|
      ranges_overlap?(
        left[:block_provider_span_start],
        left[:block_provider_span_end],
        right[:block_provider_span_start],
        right[:block_provider_span_end]
      )
    end

    descriptors.sort_by { |descriptor| descriptor[:block_provider_span_start] }
  rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
    []
  end

  private

  attr_reader :analyze_result, :content, :lines, :mapper, :profile, :projection,
    :structured_items, :words

  def provider_context_valid?
    return false unless analyze_result.is_a?(Hash)
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return false unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    @mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    return false if mapper.nil?

    @content = bounded_text(analyze_result["content"], max_bytes: MAX_CONTENT_BYTES, allow_newlines: true)
    return false if content.nil?

    pages = analyze_result["pages"]
    return false unless pages.is_a?(Array) && pages.size == MAX_PAGES

    @lines = validated_lines(pages.sole)
    return false if lines.nil?

    @words = validated_words(pages.sole)
    return false if words.nil?

    documents = analyze_result["documents"]
    return false unless documents.is_a?(Array) && documents.one? && documents.sole.is_a?(Hash)

    fields = documents.sole["fields"]
    return false unless fields.is_a?(Hash)

    items_field = fields["Items"]
    return false unless items_field.nil? || items_field.is_a?(Hash)

    @structured_items = items_field&.fetch("valueArray", nil)
    @structured_items = [] if structured_items.nil?
    structured_items.is_a?(Array) && structured_items.size <= MAX_ITEMS && structured_items.all?(Hash)
  end

  def validated_lines(page)
    return unless page.is_a?(Hash) && page["unit"] == "pixel"

    width = finite_positive_number(page["width"])
    height = finite_positive_number(page["height"])
    return if width.nil? || height.nil?

    entries = page["lines"]
    return unless entries.is_a?(Array) && entries.size.between?(4, MAX_LINES)

    validated = entries.filter_map.with_index do |entry, index|
      validated_layout_entry(
        entry,
        index:,
        word: false,
        page_width: width,
        page_height: height,
        max_content_bytes: MAX_LINE_CONTENT_BYTES
      )
    end
    return unless validated.size == entries.size
    return unless validated.each_cons(2).all? { |left, right| left[:span_end] < right[:span_start] }

    validated
  end

  def validated_words(page)
    width = finite_positive_number(page["width"])
    height = finite_positive_number(page["height"])
    entries = page["words"]
    return unless entries.is_a?(Array) && entries.size.between?(1, MAX_WORDS)

    validated = entries.filter_map.with_index do |entry, index|
      validated_layout_entry(
        entry,
        index:,
        word: true,
        page_width: width,
        page_height: height,
        max_content_bytes: MAX_WORD_CONTENT_BYTES
      )
    end
    return unless validated.size == entries.size
    return unless validated.each_cons(2).all? { |left, right| left[:span_end] <= right[:span_start] }

    line_index = 0
    valid = validated.all? do |word|
      while line_index < lines.size && word[:span_start] >= lines.fetch(line_index)[:span_end]
        line_index += 1
      end
      break false if line_index >= lines.size

      line = lines.fetch(line_index)
      next false unless range_within?(
        word[:span_start], word[:span_end], line[:span_start], line[:span_end]
      )
      next false unless bounds_within?(word[:bounds], line[:bounds], tolerance: 1)

      word[:line_index] = line_index
      true
    end

    valid ? validated : nil
  end

  def validated_layout_entry(
    entry,
    index:,
    word:,
    page_width:,
    page_height:,
    max_content_bytes:
  )
    return unless entry.is_a?(Hash)

    entry_content = bounded_text(
      entry["content"],
      max_bytes: max_content_bytes,
      allow_newlines: false
    )
    return if entry_content.blank?

    span = word ? bounded_span(entry["span"]) : single_span(entry)
    return if span.nil?
    return unless mapper.length(entry_content) == span.fetch(:length)
    return unless mapper.slice(
      content,
      offset: span.fetch(:offset),
      length: span.fetch(:length)
    ) == entry_content

    bounds = polygon_bounds(entry["polygon"], page_width:, page_height:)
    return if bounds.nil?

    {
      content: entry_content,
      span_start: span.fetch(:offset),
      span_end: span.fetch(:offset) + span.fetch(:length),
      bounds:,
      index:
    }
  end

  def ordinary_blocks
    blocks = []
    lines.each_cons(4).with_index do |(name, reference, purchased, total), index|
      next unless purchased_quantity_line?(purchased[:content])
      next unless printed_total_line?(total[:content])

      blocks << ordinary_block(
        name:,
        reference:,
        purchased_entries: [ purchased ],
        total:,
        owned_entries: [ name, reference, purchased, total ],
        index:
      )
    end
    lines.each_cons(5).with_index do |(name, reference, middle, purchased, total), index|
      if applied_unit_price_line?(reference[:content]) &&
          per_unit_discount_note?(middle[:content]) &&
          purchased_quantity_line?(purchased[:content]) &&
          printed_total_line?(total[:content])
        blocks << ordinary_block(
          name:,
          reference:,
          purchased_entries: [ purchased ],
          total:,
          owned_entries: [ name, reference, middle, purchased, total ],
          index:,
          promotional_note: middle
        )
      end

      next unless purchased_quantity_label_line?(middle[:content])
      next unless exact_quantity_value_line?(purchased[:content])
      next unless printed_total_line?(total[:content])

      blocks << ordinary_block(
        name:,
        reference:,
        purchased_entries: [ middle, purchased ],
        total:,
        owned_entries: [ name, reference, middle, purchased, total ],
        index:,
        quantity_value_entry: purchased
      )
    end
    blocks.compact
  end

  def quantity_before_reference_blocks
    lines.each_cons(4).with_index.filter_map do |(name, purchased, reference, total), index|
      next unless purchased_quantity_line?(purchased[:content])
      next unless printed_total_line?(total[:content])

      ordinary_block(
        name:,
        reference:,
        purchased_entries: [ purchased ],
        total:,
        owned_entries: [ name, purchased, reference, total ],
        index:
      )
    end
  end

  def column_blocks
    lines.each_cons(5).with_index.filter_map do |(name, header, price, quantity, total), index|
      header_match = profile.ocr_reference_pricing_item_layout_column_header_pattern.match(header[:content])
      next if header_match.nil?
      next unless column_cells_layout_valid?(name, header, price, quantity, total, header_match:)

      price_amount = exact_column_decimal(price[:content])
      purchased_amount = exact_column_decimal(quantity[:content])
      total_amount = exact_column_integer(total[:content])
      next if [ price_amount, purchased_amount, total_amount ].any?(&:nil?)

      reference_unit = header_match[:reference_unit]
      purchased_unit = header_match[:purchased_unit]
      next if reference_unit.blank? || purchased_unit.blank?

      {
        kind: :column,
        name:,
        reference: price,
        purchased_entries: [ quantity ],
        total:,
        header:,
        owned_entries: [ name, header, price, quantity, total ],
        index:,
        pseudo_reference_content: "#{price_amount}円/#{reference_unit}",
        pseudo_quantity_content: "#{purchased_amount}#{purchased_unit}",
        pseudo_total_content: total[:content],
        column_values: {
          price_amount:,
          purchased_amount:,
          total_amount:,
          reference_unit:,
          purchased_unit:
        }
      }
    end
  end

  def ordinary_block(
    name:,
    reference:,
    purchased_entries:,
    total:,
    owned_entries:,
    index:,
    promotional_note: nil,
    quantity_value_entry: nil
  )
    return unless ordinary_block_layout_valid?(owned_entries)
    return unless product_name_valid?(name, first_block_line_index: index)
    return if unsafe_block_text?(owned_entries, reference:, promotional_note:)

    purchased = quantity_value_entry || purchased_entries.last
    {
      kind: :ordinary,
      name:,
      reference:,
      purchased_entries:,
      total:,
      owned_entries:,
      index:,
      promotional_note:,
      pseudo_reference_content: reference[:content],
      pseudo_quantity_content: purchased[:content],
      pseudo_total_content: total[:content]
    }
  end

  def descriptor_for(block)
    return unless product_name_valid?(block.fetch(:name), first_block_line_index: block.fetch(:index))

    destination = destination_for(block)
    return if destination.nil?

    pseudo = pseudo_candidate(block)
    return if pseudo.nil?

    candidate = remapped_candidate(pseudo.fetch(:candidate), block, pseudo:)
    return if candidate.nil?
    return unless candidate_eligible_for_layout?(candidate)
    return unless promotional_note_consistent?(block, candidate)

    candidate_id = candidate_id_for(block)
    item_identity = destination.fetch(:item_identity)
    printed_line_total = candidate[:printed_line_total]
    return if printed_line_total.nil?
    destination_evidence = destination[:destination_evidence] || destination_evidence(block.fetch(:name))
    return if destination_evidence.nil?

    resolved_layout_item = if destination[:layout_item]
      layout_item(block, candidate, item_identity:)
    end
    return if destination[:layout_item] && resolved_layout_item.nil?

    {
      source_kind: SOURCE_KIND,
      validation_contract_version: VALIDATION_CONTRACT_VERSION,
      page_index: 0,
      candidate_id:,
      item_identity:,
      destination_kind: destination.fetch(:destination_kind),
      structured_item_index: destination[:structured_item_index],
      name_line_index: block.dig(:name, :index),
      reference_line_index: block.dig(:reference, :index),
      reference_line_provider_span_start: block.dig(:reference, :span_start),
      reference_line_provider_span_end: block.dig(:reference, :span_end),
      per_unit_discount_note_present: block[:promotional_note].present?,
      purchased_quantity_line_indexes: block.fetch(:purchased_entries).map { |entry| entry.fetch(:index) },
      printed_total_line_index: block.dig(:total, :index),
      owned_line_indexes: block.fetch(:owned_entries).map { |entry| entry.fetch(:index) }.sort,
      block_provider_span_start: block.fetch(:owned_entries).first.fetch(:span_start),
      block_provider_span_end: block.fetch(:owned_entries).last.fetch(:span_end),
      destination_evidence:,
      reference_pricing_candidate: candidate.merge(candidate_id: "#{candidate_id}_reference_pricing"),
      printed_line_total:,
      layout_item: resolved_layout_item
    }
  end

  def pseudo_candidate(block)
    pseudo_content = [
      block.fetch(:pseudo_reference_content),
      block.fetch(:pseudo_quantity_content),
      block.fetch(:pseudo_total_content)
    ].join("\n")
    pseudo_mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: mapper.index_type)
    return if pseudo_mapper.nil?

    reference_length = pseudo_mapper.length(block.fetch(:pseudo_reference_content))
    quantity_length = pseudo_mapper.length(block.fetch(:pseudo_quantity_content))
    total_length = pseudo_mapper.length(block.fetch(:pseudo_total_content))
    return if [ reference_length, quantity_length, total_length ].any?(&:nil?)

    quantity_offset = reference_length + 1
    total_offset = quantity_offset + quantity_length + 1
    item = {
      "content" => pseudo_content,
      "spans" => [ { "offset" => 0, "length" => pseudo_mapper.length(pseudo_content) } ],
      "valueObject" => {
        "Price" => {
          "content" => block.fetch(:pseudo_reference_content),
          "spans" => [ { "offset" => 0, "length" => reference_length } ]
        },
        "Quantity" => {
          "content" => block.fetch(:pseudo_quantity_content),
          "spans" => [ { "offset" => quantity_offset, "length" => quantity_length } ]
        },
        "TotalPrice" => {
          "content" => block.fetch(:pseudo_total_content),
          "spans" => [ { "offset" => total_offset, "length" => total_length } ]
        }
      }
    }
    candidates = Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items: [ item ],
      profile:,
      content: pseudo_content.freeze,
      string_index_type: mapper.index_type,
      allow_separated_tax_label: true,
      projection:
    )
    return unless candidates.one?

    {
      candidate: candidates.sole,
      mapper: pseudo_mapper,
      field_offsets: {
        price: 0,
        quantity: quantity_offset,
        total: total_offset
      },
      field_contents: {
        price: block.fetch(:pseudo_reference_content),
        quantity: block.fetch(:pseudo_quantity_content),
        total: block.fetch(:pseudo_total_content)
      }
    }
  end

  def remapped_candidate(candidate, block, pseudo:)
    remapped = candidate.deep_dup
    remapped.delete(:item_index)
    remapped[:source_kind] = SOURCE_KIND
    remapped[:provider_model_id] = SUPPORTED_MODEL_ID
    remapped[:provider_api_version] = SUPPORTED_API_VERSION
    remapped[:string_index_type] = mapper.index_type
    remapped[:validation_contract_version] = VALIDATION_CONTRACT_VERSION

    if block[:kind] == :column
      remap_column_candidate!(remapped, block)
    else
      remap_ordinary_candidate!(remapped, block, pseudo:)
    end
    remapped
  rescue KeyError, NoMethodError, TypeError
    nil
  end

  def remap_ordinary_candidate!(candidate, block, pseudo:)
    mappings = {
      reference_price: [ :price, block.fetch(:reference) ],
      reference_quantity: [ :price, block.fetch(:reference) ],
      purchased_quantity: [ :quantity, block.fetch(:purchased_entries).last ],
      printed_line_total: [ :total, block.fetch(:total) ]
    }
    mappings.each do |component_name, (field_name, entry)|
      component = candidate[component_name]
      next if component.nil?

      component[:evidence] = remap_pseudo_evidence(
        component[:evidence],
        field_name:,
        target: entry,
        pseudo:
      )
      raise KeyError if component[:evidence].nil?
    end

    if candidate[:tax_inclusion_evidence]
      candidate[:tax_inclusion_evidence] = remap_pseudo_evidence(
        candidate[:tax_inclusion_evidence],
        field_name: :price,
        target: block.fetch(:reference),
        pseudo:
      )
      raise KeyError if candidate[:tax_inclusion_evidence].nil?
    end
  end

  def remap_column_candidate!(candidate, block)
    values = block.fetch(:column_values)
    candidate.fetch(:reference_price)[:evidence] = exact_entry_evidence(block.fetch(:reference))
    candidate.fetch(:reference_quantity)[:evidence] = column_header_unit_evidence(
      block.fetch(:header),
      values.fetch(:reference_unit),
      occurrence: 0
    )
    candidate.fetch(:purchased_quantity)[:evidence] = exact_entry_evidence(
      block.fetch(:purchased_entries).sole
    )
    candidate.fetch(:printed_line_total)[:evidence] = exact_entry_evidence(block.fetch(:total))
    raise KeyError if [
      candidate.dig(:reference_price, :evidence),
      candidate.dig(:reference_quantity, :evidence),
      candidate.dig(:purchased_quantity, :evidence),
      candidate.dig(:printed_line_total, :evidence)
    ].any?(&:nil?)
  end

  def remap_pseudo_evidence(evidence, field_name:, target:, pseudo:)
    return unless evidence.is_a?(Hash)

    start_value = evidence[:provider_span_start]
    end_value = evidence[:provider_span_end]
    field_offset = pseudo.dig(:field_offsets, field_name)
    field_content = pseudo.dig(:field_contents, field_name)
    return unless [ start_value, end_value, field_offset ].all?(Integer)

    relative_start = start_value - field_offset
    relative_length = end_value - start_value
    byte_range = pseudo.fetch(:mapper).byte_range_for_span(
      field_content,
      offset: relative_start,
      length: relative_length
    )
    return if byte_range.nil?

    provider_span = mapper.span_for_bytes(
      target.fetch(:content),
      byte_offset: byte_range.begin,
      byte_length: byte_range.size
    )
    return if provider_span.nil?

    structural_evidence(
      target,
      start_offset: target.fetch(:span_start) + provider_span.fetch(:offset),
      end_offset: target.fetch(:span_start) + provider_span.fetch(:offset) + provider_span.fetch(:length)
    )
  end

  def exact_entry_evidence(entry)
    structural_evidence(
      entry,
      start_offset: entry.fetch(:span_start),
      end_offset: entry.fetch(:span_end)
    )
  end

  def column_header_unit_evidence(header, unit, occurrence:)
    indexes = []
    offset = 0
    while (index = header.fetch(:content).index(unit, offset))
      indexes << index
      offset = index + unit.length
    end
    index = indexes[occurrence]
    return if index.nil?

    byte_offset = header.fetch(:content)[0...index].bytesize
    provider_span = mapper.span_for_bytes(
      header.fetch(:content),
      byte_offset:,
      byte_length: unit.bytesize
    )
    return if provider_span.nil?

    structural_evidence(
      header,
      start_offset: header.fetch(:span_start) + provider_span.fetch(:offset),
      end_offset: header.fetch(:span_start) + provider_span.fetch(:offset) + provider_span.fetch(:length)
    )
  end

  def structural_evidence(entry, start_offset:, end_offset:)
    return unless range_within?(
      start_offset,
      end_offset,
      entry.fetch(:span_start),
      entry.fetch(:span_end)
    )

    {
      source_provider: SOURCE_KIND,
      source_field_path: "pages[0].lines[#{entry.fetch(:index)}]",
      page_index: 0,
      line_index: entry.fetch(:index),
      string_index_type: mapper.index_type,
      provider_span_start: start_offset,
      provider_span_end: end_offset
    }
  end

  def candidate_eligible_for_layout?(candidate)
    state = candidate[:validation_state]
    reasons = Array(candidate[:rejection_reasons]).sort
    return false unless state == "valid" || (state == "ambiguous" && reasons == [ "ambiguous_tax_inclusion" ])
    return false unless candidate[:printed_line_total]

    corroboration = candidate[:corroboration]
    corroboration.is_a?(Hash) &&
      corroboration[:projected_amount].to_s == candidate.dig(:printed_line_total, :amount)
  end

  def promotional_note_consistent?(block, candidate)
    note = block[:promotional_note]
    return true if note.nil?

    match = profile.ocr_reference_pricing_item_layout_per_unit_discount_note_pattern.match(note[:content])
    return false if match.nil?

    unit = match[:unit]
    basis_quantity = exact_decimal_value(match[:basis_quantity].presence || "1")
    expected_basis_quantity = exact_decimal_value(candidate.dig(:reference_quantity, :amount))
    resolution = profile.resolve_quantity_unit(unit)
    basis_quantity && expected_basis_quantity && basis_quantity == expected_basis_quantity &&
      resolution.known? && resolution.code == candidate.dig(:reference_quantity, :unit_code)
  end

  def destination_for(block)
    structured = exact_structured_destination(block)
    structured ||= exact_single_structured_destination(block)
    return structured if structured
    if block[:kind] == :column
      replacement = replacement_destination(block)
      return replacement if replacement
    end
    return if structured_items.any?

    {
      destination_kind: "azure_layout_item",
      structured_item_index: nil,
      item_identity: layout_item_identity(block),
      layout_item: true
    }
  end

  def exact_structured_destination(block)
    block_start = block.fetch(:owned_entries).first.fetch(:span_start)
    block_end = block.fetch(:owned_entries).last.fetch(:span_end)
    matches = structured_items.filter_map.with_index do |item, item_index|
      parent = exact_structured_parent_span(item)
      next if parent.nil?
      next unless range_within?(block_start, block_end, parent.begin, parent.end)
      next unless exact_structured_description?(item, block.fetch(:name), parent:)

      {
        destination_kind: "azure_structured_item",
        structured_item_index: item_index,
        item_identity: "azure_structured_item_i#{item_index}_s#{parent.begin}_e#{parent.end}",
        layout_item: false
      }
    end

    matches.sole if matches.one?
  end

  def exact_single_structured_destination(block)
    return unless structured_items.one?

    item = structured_items.sole
    parent = exact_structured_parent_span(item)
    return if parent.nil?

    name = block.fetch(:name)
    reference = block.fetch(:reference)
    purchased = block.fetch(:purchased_entries).last
    return unless parent.begin == name.fetch(:span_start)
    return unless parent.end == reference.fetch(:span_end)
    return unless purchased.fetch(:span_start) > parent.end
    return unless exact_structured_description?(item, name, parent:)
    return unless exact_field_entry?(item.dig("valueObject", "Price"), reference)

    {
      destination_kind: "azure_structured_item",
      structured_item_index: 0,
      item_identity: "azure_structured_item_i0_s#{parent.begin}_e#{parent.end}",
      layout_item: false,
      destination_evidence: exact_entry_evidence(name)
    }
  end

  def replacement_destination(block)
    cell_start = block.fetch(:reference).fetch(:span_start)
    cell_end = block.fetch(:total).fetch(:span_end)
    matches = structured_items.filter_map.with_index do |item, item_index|
      parent = exact_structured_parent_span(item)
      next if parent.nil? || parent.begin != cell_start || parent.end != cell_end

      fields = item["valueObject"]
      next unless fields.is_a?(Hash)
      next unless exact_field_entry?(fields["Description"], block.fetch(:reference))
      next unless exact_field_entry?(fields["Price"], block.fetch(:purchased_entries).sole)
      next unless exact_field_entry?(fields["TotalPrice"], block.fetch(:total))

      {
        destination_kind: "azure_layout_item",
        structured_item_index: item_index,
        item_identity: layout_item_identity(block),
        layout_item: true
      }
    end

    matches.sole if matches.one?
  end

  def exact_structured_parent_span(item)
    item_content = bounded_text(item["content"], max_bytes: MAX_ITEM_FIELD_BYTES, allow_newlines: true)
    span = single_span(item)
    return if item_content.nil? || span.nil?
    return unless mapper.length(item_content) == span.fetch(:length)
    return unless mapper.slice(content, offset: span.fetch(:offset), length: span.fetch(:length)) == item_content

    span.fetch(:offset)...(span.fetch(:offset) + span.fetch(:length))
  end

  def exact_structured_description?(item, name, parent:)
    description = item.dig("valueObject", "Description")
    return false unless description.is_a?(Hash)
    return false unless description["content"] == name[:content]
    return false unless description["valueString"] == name[:content]

    span = single_span(description)
    span && span.fetch(:offset) == name[:span_start] &&
      span.fetch(:offset) + span.fetch(:length) == name[:span_end] &&
      range_within?(name[:span_start], name[:span_end], parent.begin, parent.end)
  end

  def exact_field_entry?(field, entry)
    return false unless field.is_a?(Hash) && field["content"] == entry[:content]

    span = single_span(field)
    span && span.fetch(:offset) == entry[:span_start] &&
      span.fetch(:offset) + span.fetch(:length) == entry[:span_end]
  end

  def layout_item(block, candidate, item_identity:)
    amount = exact_integer(candidate.dig(:printed_line_total, :amount))
    return if amount.nil?

    {
      raw_text: block.dig(:name, :content),
      price: candidate.dig(:reference_price, :amount),
      quantity: candidate.dig(:purchased_quantity, :amount),
      quantity_unit_code: candidate.dig(:purchased_quantity, :unit_code),
      quantity_unit_status: candidate.dig(:purchased_quantity, :unit_status),
      line_total: amount,
      original_line_total: amount,
      discount_amount: nil,
      discount_rate: nil,
      tax_rate: nil,
      ocr_item_identity: item_identity
    }
  end

  def layout_item_identity(block)
    name = block.fetch(:name)
    "azure_item_layout_item_p0_name_l#{name.fetch(:index)}_s#{name.fetch(:span_start)}_e#{name.fetch(:span_end)}_" \
      "ref_l#{block.fetch(:reference).fetch(:index)}_qty_l#{block.fetch(:purchased_entries).last.fetch(:index)}_" \
      "total_l#{block.fetch(:total).fetch(:index)}"
  end

  def candidate_id_for(block)
    "azure_item_layout_p0_name_l#{block.fetch(:name).fetch(:index)}_" \
      "ref_l#{block.fetch(:reference).fetch(:index)}_" \
      "qty_l#{block.fetch(:purchased_entries).last.fetch(:index)}_" \
      "total_l#{block.fetch(:total).fetch(:index)}"
  end

  def destination_evidence(name)
    name_words = words.select { |word| word[:line_index] == name[:index] }
    return if name_words.empty? || name_words.size > MAX_PRODUCT_WORDS
    return unless name_words.first[:span_start] == name[:span_start]
    return unless name_words.last[:span_end] == name[:span_end]
    return unless name_words.each_cons(2).all? { |left, right| left[:span_end] == right[:span_start] }

    exact_entry_evidence(name).merge(
      word_spans: name_words.map do |word|
        {
          source_field_path: "pages[0].words[#{word.fetch(:index)}]",
          word_index: word.fetch(:index),
          provider_span_start: word.fetch(:span_start),
          provider_span_end: word.fetch(:span_end)
        }
      end
    )
  end

  def product_name_valid?(name, first_block_line_index:)
    value = name[:content]
    return false unless value.unicode_normalize(:nfkc) == value
    return false unless value.bytesize <= MAX_PRODUCT_NAME_BYTES
    return false unless value.scan(/\X/).size.between?(2, MAX_PRODUCT_NAME_GRAPHEMES)
    return false unless value.match?(PRODUCT_NAME_TOKEN_PATTERN)
    return false if destination_conflict?(value)
    return false if value.match?(profile.ocr_reference_pricing_line_group_package_or_uncertain_pattern)
    return false unless lines.count { |line| line[:content] == value } == 1
    return false if destination_evidence(name).nil? && exact_structured_name_line(name).nil?
    return false if non_item_document_field_overlap?(name)

    previous = lines[first_block_line_index - 1] if first_block_line_index.positive?
    return false if previous && product_like_line?(previous[:content])

    true
  end

  def exact_structured_name_line(name)
    matches = structured_items.select do |item|
      parent = exact_structured_parent_span(item)
      parent && exact_structured_description?(item, name, parent:)
    end

    matches.sole if matches.one?
  end

  def product_like_line?(value)
    return false if destination_conflict?(value)
    return false if value.match?(profile.ocr_reference_pricing_line_group_package_or_uncertain_pattern)
    return false if value.match?(profile.ocr_reference_pricing_item_layout_printed_total_line_pattern)
    return false if value.match?(profile.ocr_reference_pricing_item_layout_purchased_quantity_line_pattern)
    return false if value.include?("/") || value.include?("／")

    value.match?(PRODUCT_NAME_TOKEN_PATTERN) && !value.match?(/[0-9０-９]{2,}/)
  end

  def destination_conflict?(value)
    profile.ocr_reference_pricing_line_group_destination_identifier_conflict_patterns.any? do |pattern|
      value.match?(pattern)
    end
  end

  def non_item_document_field_overlap?(name)
    fields = analyze_result.dig("documents", 0, "fields")
    return true unless fields.is_a?(Hash)

    fields.except("Items").any? do |field_name, field|
      next true unless field.is_a?(Hash)

      field_texts = [ field["content"], field["valueString"] ].compact
      overlap = field_texts.any? { |text| text.is_a?(String) && text.include?(name[:content]) } ||
        Array(field["spans"]).any? do |span|
          bounded = bounded_span(span)
          bounded && ranges_overlap?(
            bounded.fetch(:offset),
            bounded.fetch(:offset) + bounded.fetch(:length),
            name[:span_start],
            name[:span_end]
          )
        end
      next false unless overlap

      field_name != "PaymentMethods" ||
        [ name[:content], *field_texts ].any? do |text|
          text.is_a?(String) && text.match?(profile.ocr_payment_anchor_pattern)
        end
    end
  rescue EncodingError, NoMethodError, TypeError
    true
  end

  def ordinary_block_layout_valid?(entries)
    exact_line_sequence?(entries) && entries.each_cons(2).all? do |upper, lower|
      vertical_neighbors?(upper, lower)
    end
  end

  def column_cells_layout_valid?(name, header, price, quantity, total, header_match:)
    entries = [ name, header, price, quantity, total ]
    return false unless exact_line_sequence?(entries)
    return false unless vertical_neighbors?(name, header)
    return false unless [ price, quantity, total ].all? { |cell| vertical_neighbors?(header, cell) }
    return false unless [ price, quantity, total ].each_cons(2).all? do |left, right|
      left.dig(:bounds, :right) < right.dig(:bounds, :left)
    end

    cells = [ price, quantity, total ]
    return false unless cells.all? do |cell|
      overlap = [ cell.dig(:bounds, :bottom), cells.first.dig(:bounds, :bottom) ].min -
        [ cell.dig(:bounds, :top), cells.first.dig(:bounds, :top) ].max
      height = [ cell.dig(:bounds, :height), cells.first.dig(:bounds, :height) ].min
      height&.positive? && overlap / height >= MIN_COLUMN_VERTICAL_OVERLAP_RATIO
    end

    heading_bounds = %w[price_heading quantity_heading total_heading].map do |capture_name|
      column_heading_bounds(header, header_match, capture_name:)
    end
    return false if heading_bounds.any?(&:nil?)

    cells.zip(heading_bounds).all? do |cell, heading|
      center = (cell.dig(:bounds, :left) + cell.dig(:bounds, :right)) / 2
      center.between?(heading[:left], heading[:right])
    end
  end

  def exact_line_sequence?(entries)
    entries.each_cons(2).all? do |upper, lower|
      lower[:span_start] == upper[:span_end] + 1 &&
        mapper.slice(content, offset: upper[:span_end], length: 1) == "\n"
    end
  end

  def vertical_neighbors?(upper, lower)
    return false unless upper.dig(:bounds, :bottom) <= lower.dig(:bounds, :top)

    gap = lower.dig(:bounds, :top) - upper.dig(:bounds, :bottom)
    height = [ upper.dig(:bounds, :height), lower.dig(:bounds, :height) ].max
    height&.positive? && gap / height <= MAX_VERTICAL_GAP_RATIO
  end

  def column_heading_bounds(header, header_match, capture_name:)
    capture_start = header_match.begin(capture_name)
    capture_end = header_match.end(capture_name)
    return if capture_start.nil? || capture_end.nil? || capture_end <= capture_start

    byte_start = header.fetch(:content)[0...capture_start].bytesize
    byte_end = header.fetch(:content)[0...capture_end].bytesize
    provider_span = mapper.span_for_bytes(
      header.fetch(:content),
      byte_offset: byte_start,
      byte_length: byte_end - byte_start
    )
    return if provider_span.nil?

    span_start = header.fetch(:span_start) + provider_span.fetch(:offset)
    span_end = span_start + provider_span.fetch(:length)
    heading_words = words.select do |word|
      word[:line_index] == header[:index] &&
        range_within?(word[:span_start], word[:span_end], span_start, span_end)
    end
    return if heading_words.empty?
    return unless heading_words.first[:span_start] == span_start
    return unless heading_words.last[:span_end] == span_end
    return unless heading_words.each_cons(2).all? { |left, right| left[:span_end] == right[:span_start] }

    left = heading_words.map { |word| word.dig(:bounds, :left) }.min
    right = heading_words.map { |word| word.dig(:bounds, :right) }.max
    top = heading_words.map { |word| word.dig(:bounds, :top) }.min
    bottom = heading_words.map { |word| word.dig(:bounds, :bottom) }.max
    { left:, right:, top:, bottom:, width: right - left, height: bottom - top }
  end

  def unsafe_block_text?(entries, reference:, promotional_note:)
    entries.any? do |entry|
      text = entry[:content]
      next false if promotional_note && entry.equal?(promotional_note)
      next false if entry.equal?(entries.first)
      next false if entry.equal?(reference)
      next false if printed_total_line?(text)
      next false if purchased_quantity_line?(text) || purchased_quantity_label_line?(text)

      text.match?(profile.ocr_reference_pricing_line_group_package_or_uncertain_pattern) ||
        text.match?(profile.ocr_reference_pricing_line_group_discount_conflict_pattern) ||
        (text.match?(profile.ocr_item_discount_keyword_pattern) &&
          !text.match?(profile.ocr_post_discount_price_basis_pattern))
    end
  end

  def purchased_quantity_line?(value)
    value.match?(profile.ocr_reference_pricing_item_layout_purchased_quantity_line_pattern)
  end

  def purchased_quantity_label_line?(value)
    value.match?(profile.ocr_reference_pricing_item_layout_purchased_quantity_label_line_pattern)
  end

  def printed_total_line?(value)
    value.match?(profile.ocr_reference_pricing_item_layout_printed_total_line_pattern)
  end

  def applied_unit_price_line?(value)
    value.match?(profile.ocr_reference_pricing_item_layout_applied_unit_price_line_pattern)
  end

  def per_unit_discount_note?(value)
    value.match?(profile.ocr_reference_pricing_item_layout_per_unit_discount_note_pattern)
  end

  def exact_quantity_value_line?(value)
    normalized = value.unicode_normalize(:nfkc)
    normalized.match?(/\A[ \t]*(?:0|[1-9][0-9]*)(?:\.[0-9]+)?[ \t]*\p{L}{1,24}[ \t]*\z/u)
  end

  def exact_column_decimal(value)
    match = COLUMN_CELL_PATTERN.match(value.unicode_normalize(:nfkc))
    return if match.nil?

    normalized = match[:amount].delete(",")
    normalized if normalized.match?(DECIMAL_PATTERN)
  end

  def exact_column_integer(value)
    value = exact_column_decimal(value)
    value if value&.match?(INTEGER_AMOUNT_PATTERN)
  end

  def exact_integer(value)
    return unless value.is_a?(String) && value.match?(INTEGER_AMOUNT_PATTERN)

    Integer(value, 10)
  rescue ArgumentError
    nil
  end

  def exact_decimal_value(value)
    return unless value.is_a?(String) && value.valid_encoding?
    return if value.bytesize > MAX_DECIMAL_TOKEN_BYTES

    normalized = value.unicode_normalize(:nfkc)
    return unless normalized.match?(DECIMAL_PATTERN)

    BigDecimal(normalized)
  rescue ArgumentError
    nil
  end

  def bounded_text(value, max_bytes:, allow_newlines:)
    return unless value.is_a?(String) && value.valid_encoding?
    return if value.bytesize > max_bytes
    return if value.match?(CONTROL_CHARACTER_PATTERN)
    return if !allow_newlines && value.match?(/[\r\n\u0085\u2028\u2029]/)

    value
  end

  def single_span(value)
    spans = value["spans"]
    return unless spans.is_a?(Array) && spans.size == 1

    bounded_span(spans.sole)
  end

  def bounded_span(value)
    return unless value.is_a?(Hash)

    offset = value["offset"]
    length = value["length"]
    return unless offset.is_a?(Integer) && length.is_a?(Integer)
    return if offset.negative? || length <= 0
    return if offset > MAX_PROVIDER_SPAN_VALUE || length > MAX_PROVIDER_SPAN_VALUE - offset

    { offset:, length: }
  end

  def polygon_bounds(value, page_width:, page_height:)
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
      width: Rational((right - left).to_s),
      height: Rational((bottom - top).to_s)
    }
  rescue ArgumentError, NoMethodError, TypeError
    nil
  end

  def finite_positive_number(value)
    return unless value.is_a?(Numeric) && value.finite? && value.positive?
    return if value > MAX_PAGE_DIMENSION

    Rational(value.to_s)
  rescue ArgumentError
    nil
  end

  def bounds_within?(inner, outer, tolerance:)
    inner[:left] >= outer[:left] - tolerance &&
      inner[:right] <= outer[:right] + tolerance &&
      inner[:top] >= outer[:top] - tolerance &&
      inner[:bottom] <= outer[:bottom] + tolerance
  end

  def range_within?(inner_start, inner_end, outer_start, outer_end)
    [ inner_start, inner_end, outer_start, outer_end ].all?(Integer) &&
      inner_start >= outer_start && inner_end <= outer_end && inner_end > inner_start
  end

  def ranges_overlap?(left_start, left_end, right_start, right_end)
    left_start < right_end && right_start < left_end
  end
end
