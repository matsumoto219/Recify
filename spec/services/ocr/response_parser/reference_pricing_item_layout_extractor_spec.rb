require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingItemLayoutExtractor do
  def text_element_length(value)
    value.scan(/\X/).length
  end

  def synthetic_analyze_result(lines, layout: {}, structured_items: [], document_fields: {})
    content = lines.join("\n")
    cursor = 0
    words = []
    page_lines = lines.each_with_index.map do |line, line_index|
      line_length = text_element_length(line)
      geometry = layout.fetch(line_index, {})
      left = geometry.fetch(:left, 20)
      top = geometry.fetch(:top, 20 + (line_index * 22))
      width = geometry.fetch(:width, [ line_length * 10, 30 ].max)
      height = geometry.fetch(:height, 16)
      word_lefts = geometry[:word_lefts]

      line.to_enum(:scan, /\S+/).each_with_index do |word, word_index|
        match = Regexp.last_match
        prefix = line[0...match.begin(0)]
        word_offset = cursor + text_element_length(prefix)
        word_left = word_lefts&.fetch(word_index) || left + (text_element_length(prefix) * 10)
        word_width = [ text_element_length(word) * 10, 10 ].max
        words << {
          'content' => word,
          'polygon' => [
            word_left, top, word_left + word_width, top,
            word_left + word_width, top + height, word_left, top + height
          ],
          'confidence' => 0.99,
          'span' => { 'offset' => word_offset, 'length' => text_element_length(word) }
        }
      end

      entry = {
        'content' => line,
        'polygon' => [ left, top, left + width, top, left + width, top + height, left, top + height ],
        'spans' => [ { 'offset' => cursor, 'length' => line_length } ]
      }
      cursor += line_length + 1
      entry
    end

    {
      'apiVersion' => '2024-11-30',
      'modelId' => 'prebuilt-receipt',
      'stringIndexType' => 'textElements',
      'content' => content,
      'pages' => [
        {
          'pageNumber' => 1,
          'width' => 320,
          'height' => [ 120, lines.length * 30 ].max,
          'unit' => 'pixel',
          'words' => words,
          'lines' => page_lines
        }
      ],
      'documents' => [
        {
          'docType' => 'receipt.retailMeal',
          'fields' => document_fields.merge(
            'Items' => { 'type' => 'array', 'valueArray' => structured_items }
          )
        }
      ]
    }
  end

  def extract(
    lines,
    layout: {},
    structured_items: [],
    document_fields: {},
    profile: ReceiptAnalysisProfiles.fetch('JPN')
  )
    analyze_result = synthetic_analyze_result(lines, layout:, structured_items:, document_fields:)

    described_class.call(
      analyze_result:,
      profile:,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
  end

  def expect_reference_source(block, price:, basis:, basis_unit:, purchased:, purchased_unit:)
    candidate = block.fetch(:reference_pricing_candidate)

    aggregate_failures do
      expect(candidate[:reference_price]).to include(amount: price)
      expect(candidate[:reference_quantity]).to include(
        amount: basis,
        unit_code: basis_unit,
        unit_status: 'known'
      )
      expect(candidate[:purchased_quantity]).to include(
        amount: purchased,
        unit_code: purchased_unit,
        unit_status: 'known'
      )
    end
  end

  it 'extracts an exact item-local reference, purchased quantity, and printed total block' do
    block = extract([
      '架空計算店',
      '例示量売品A',
      '税込 498円/100g',
      '計量 342g',
      '1,703円',
      '合計 1,703円'
    ]).sole

    aggregate_failures do
      expect(block).to include(
        source_kind: 'azure_item_layout',
        validation_contract_version: 'azure_item_layout_v1',
        page_index: 0,
        candidate_id: 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4',
        destination_kind: 'azure_layout_item',
        structured_item_index: nil,
        name_line_index: 1,
        reference_line_index: 2,
        reference_line_provider_span_start: 13,
        reference_line_provider_span_end: 25,
        per_unit_discount_note_present: false,
        purchased_quantity_line_indexes: [ 3 ],
        printed_total_line_index: 4,
        owned_line_indexes: [ 1, 2, 3, 4 ]
      )
      expect(block[:item_identity]).to match(
        /\Aazure_item_layout_item_p0_name_l1_s\d+_e\d+_ref_l2_qty_l3_total_l4\z/
      )
      expect(block[:destination_evidence]).to include(
        source_provider: 'azure_item_layout',
        source_field_path: 'pages[0].lines[1]',
        page_index: 0,
        line_index: 1,
        string_index_type: 'textElements'
      )
      expect(block.dig(:reference_pricing_candidate, :validation_state)).to eq('valid')
      expect(block.dig(:reference_pricing_candidate, :reference_price_tax_inclusion)).to eq('gross')
      expect(block.dig(:printed_line_total, :amount)).to eq('1703')
      expect(block.dig(:layout_item, :raw_text)).to eq('例示量売品A')
      expect(block.dig(:layout_item, :ocr_item_identity)).to eq(block[:item_identity])
      expect(block.to_json).not_to include('架空計算店')
    end
    expect_reference_source(
      block,
      price: '498',
      basis: '100',
      basis_unit: 'gram',
      purchased: '342',
      purchased_unit: 'gram'
    )
  end

  it 'accepts the strong item-total label only inside a complete strict layout block' do
    labeled = extract([
      '架空計算店',
      '例示量売品A',
      '税込 498円/100g',
      '計量 342g',
      '明細計 1,703円',
      '合計 1,703円'
    ]).sole
    full_width = extract([
      '架空計算店',
      '例示量売品A',
      '税込 498円/100g',
      '計量 342g',
      '明細計：￥１，７０３',
      '合計 1,703円'
    ]).sole
    rejected = [
      [ '明細計', '合計 1,703円' ],
      [ '明細小計 1,703円', '合計 1,703円' ],
      [ '小計 1,703円', '合計 1,703円' ],
      [ '合計 1,703円', '合計 1,703円' ],
      [ 'お支払 1,703円', '合計 1,703円' ]
    ].map do |total_line, summary_line|
      extract([
        '架空計算店',
        '例示量売品A',
        '税込 498円/100g',
        '計量 342g',
        total_line,
        summary_line
      ])
    end

    aggregate_failures do
      expect(labeled.dig(:printed_line_total, :amount)).to eq('1703')
      expect(labeled[:printed_total_line_index]).to eq(4)
      expect(full_width.dig(:printed_line_total, :amount)).to eq('1703')
      expect(full_width[:printed_total_line_index]).to eq(4)
      expect(rejected).to all(eq([]))
    end
  end

  it 'keeps an applied unit-price block with an exact informational per-unit discount note' do
    block = extract([
      '架空給油所A',
      '例示給油商品A',
      '特典適用後単価 160円/L',
      '会員値引 3円/L引',
      '給油量 20.74L',
      '金額 3,318円',
      '合計 3,318円'
    ]).sole

    aggregate_failures do
      expect(block).to include(
        reference_line_index: 2,
        per_unit_discount_note_present: true,
        purchased_quantity_line_indexes: [ 4 ],
        printed_total_line_index: 5,
        owned_line_indexes: [ 1, 2, 3, 4, 5 ]
      )
      expect(block.dig(:reference_pricing_candidate, :validation_state)).to eq('ambiguous')
      expect(block.dig(:reference_pricing_candidate, :rejection_reasons)).to include('ambiguous_tax_inclusion')
      expect(block.dig(:layout_item, :discount_amount)).to be_nil
    end
    expect_reference_source(
      block,
      price: '160',
      basis: '1',
      basis_unit: 'liter',
      purchased: '20.74',
      purchased_unit: 'liter'
    )
  end

  it 'rejects a promotional note whose quantity basis differs from the applied unit price' do
    blocks = extract([
      '架空給油所A',
      '例示給油商品A',
      '特典適用後単価 160円/L',
      '会員値引 3円/100L引',
      '給油量 20.74L',
      '金額 3,318円',
      '合計 3,318円'
    ])

    expect(blocks).to eq([])
  end

  it 'accepts one exact purchased-quantity value line after its label' do
    block = extract([
      '架空量売店B',
      '例示飲料B',
      '税込 120円/500ml',
      '給油量',
      '1.5L',
      '金額 360円',
      '合計 360円'
    ]).sole

    aggregate_failures do
      expect(block[:purchased_quantity_line_indexes]).to eq([ 3, 4 ])
      expect(block[:owned_line_indexes]).to eq([ 1, 2, 3, 4, 5 ])
      expect_reference_source(
        block,
        price: '120',
        basis: '500',
        basis_unit: 'milliliter',
        purchased: '1.5',
        purchased_unit: 'liter'
      )
    end
  end

  it 'accepts the observed purchased-quantity-before-reference fuel layout' do
    block = extract([
      '架空給油所C',
      '例示給油商品C',
      '給油量 8.18L',
      '税込 @139円/L',
      '金額 1,137円',
      '合計 1,137円'
    ]).sole

    aggregate_failures do
      expect(block).to include(
        reference_line_index: 3,
        purchased_quantity_line_indexes: [ 2 ],
        printed_total_line_index: 4,
        owned_line_indexes: [ 1, 2, 3, 4 ]
      )
      expect_reference_source(
        block,
        price: '139',
        basis: '1',
        basis_unit: 'liter',
        purchased: '8.18',
        purchased_unit: 'liter'
      )
    end
  end

  it 'binds exactly three same-row cells to an exact column header' do
    lines = [
      '架空給油所D',
      '例示給油商品D',
      '単価(円/L) 数量(L) 金額(円)',
      '169',
      '49.80',
      '8,416',
      '合計 8,416円'
    ]
    layout = {
      2 => { left: 20, width: 230, word_lefts: [ 20, 100, 170 ] },
      3 => { left: 20, top: 86, width: 30 },
      4 => { left: 100, top: 86, width: 50 },
      5 => { left: 170, top: 86, width: 50 }
    }

    block = extract(lines, layout:).sole

    aggregate_failures do
      expect(block).to include(
        candidate_id: 'azure_item_layout_p0_name_l1_ref_l3_qty_l4_total_l5',
        name_line_index: 1,
        reference_line_index: 3,
        purchased_quantity_line_indexes: [ 4 ],
        printed_total_line_index: 5,
        owned_line_indexes: [ 1, 2, 3, 4, 5 ]
      )
      expect_reference_source(
        block,
        price: '169',
        basis: '1',
        basis_unit: 'liter',
        purchased: '49.8',
        purchased_unit: 'liter'
      )
    end
  end

  it 'ignores an Azure payment-field fragment that has no payment semantics' do
    lines = [
      '架空給油所D',
      '例示給油商品D',
      '単価(円/L) 数量(L) 金額(円)',
      '169',
      '49.80',
      '8,416',
      '合計 8,416円'
    ]
    layout = {
      2 => { left: 20, width: 230, word_lefts: [ 20, 100, 170 ] },
      3 => { left: 20, top: 86, width: 30 },
      4 => { left: 100, top: 86, width: 50 },
      5 => { left: 170, top: 86, width: 50 }
    }
    result = synthetic_analyze_result(lines, layout:)
    name_line = result.dig('pages', 0, 'lines', 1)
    name_span = name_line.fetch('spans').sole
    result.dig('documents', 0, 'fields')['PaymentMethods'] = {
      'content' => '油商品D',
      'spans' => [
        {
          'offset' => name_span.fetch('offset') + 3,
          'length' => 4
        }
      ]
    }

    block = described_class.call(
      analyze_result: result,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    ).sole

    expect(block[:destination_kind]).to eq('azure_layout_item')
  end

  it 'reuses one exact structured item destination without fabricating an Azure item index' do
    lines = [
      '架空量売店E',
      '例示量売品E',
      '税込 475円/100g',
      '計量 320g',
      '1,520円',
      '合計 1,520円'
    ]
    result = synthetic_analyze_result(lines)
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: 'textElements')
    content = result.fetch('content')
    block_start = content.index('例示量売品E')
    block_end = content.index('1,520円') + '1,520円'.length
    name_start = content.index('例示量売品E')
    total_start = content.index('1,520円')
    structured_items = [
      {
        'content' => content[block_start...block_end],
        'spans' => [ { 'offset' => block_start, 'length' => block_end - block_start } ],
        'valueObject' => {
          'Description' => {
            'content' => '例示量売品E',
            'valueString' => '例示量売品E',
            'spans' => [ { 'offset' => name_start, 'length' => mapper.length('例示量売品E') } ]
          },
          'TotalPrice' => {
            'content' => '1,520円',
            'valueCurrency' => {
              'currencyCode' => 'JPY',
              'currencySymbol' => '円',
              'amount' => 1520
            },
            'spans' => [ { 'offset' => total_start, 'length' => mapper.length('1,520円') } ]
          }
        }
      }
    ]
    result.dig('documents', 0, 'fields', 'Items')['valueArray'] = structured_items

    block = described_class.call(
      analyze_result: result,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    ).sole

    aggregate_failures do
      expect(block).to include(
        destination_kind: 'azure_structured_item',
        structured_item_index: 0,
        item_identity: "azure_structured_item_i0_s#{block_start}_e#{block_end}",
        layout_item: nil
      )
      expect(block[:candidate_id]).to start_with('azure_item_layout_')
      expect(block[:candidate_id]).not_to include('azure_items_0')
    end
  end

  it 'links one exact structured destination whose parent ends before the layout quantity and total' do
    lines = [
      '架空量売店F',
      '例示量売確認品F',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '合計 600円'
    ]
    result = synthetic_analyze_result(lines)
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: 'textElements')
    content = result.fetch('content')
    name_line = result.dig('pages', 0, 'lines', 1)
    reference_line = result.dig('pages', 0, 'lines', 2)
    name_start = name_line.dig('spans', 0, 'offset')
    name_end = name_start + name_line.dig('spans', 0, 'length')
    reference_start = reference_line.dig('spans', 0, 'offset')
    reference_end = reference_start + reference_line.dig('spans', 0, 'length')
    structured_item = {
      'content' => content[name_start...reference_end],
      'spans' => [ { 'offset' => name_start, 'length' => reference_end - name_start } ],
      'valueObject' => {
        'Description' => {
          'content' => lines[1],
          'valueString' => lines[1],
          'spans' => [ { 'offset' => name_start, 'length' => mapper.length(lines[1]) } ]
        },
        'Price' => {
          'content' => lines[2],
          'spans' => [ { 'offset' => reference_start, 'length' => mapper.length(lines[2]) } ]
        }
      }
    }
    result.dig('documents', 0, 'fields', 'Items')['valueArray'] = [ structured_item ]
    words = result.dig('pages', 0, 'words')
    words.reject! do |word|
      offset = word.dig('span', 'offset')
      offset >= name_start && offset < name_end
    end
    name_bounds = name_line.fetch('polygon')
    lines[1].scan(/\X/).each_with_index do |character, index|
      left = name_bounds[0] + (index * 10)
      top = name_bounds[1]
      words << {
        'content' => character,
        'polygon' => [ left, top, left + 10, top, left + 10, top + 16, left, top + 16 ],
        'confidence' => 0.99,
        'span' => { 'offset' => name_start + index, 'length' => 1 }
      }
    end
    words.sort_by! { |word| word.dig('span', 'offset') }

    block = described_class.call(
      analyze_result: result,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    ).sole

    aggregate_failures do
      expect(block).to include(
        destination_kind: 'azure_structured_item',
        structured_item_index: 0,
        item_identity: "azure_structured_item_i0_s#{name_start}_e#{reference_end}",
        layout_item: nil,
        reference_line_provider_span_start: reference_start,
        reference_line_provider_span_end: reference_end,
        purchased_quantity_line_indexes: [ 3 ],
        printed_total_line_index: 4
      )
      expect(block[:destination_evidence]).to include(
        source_provider: 'azure_item_layout',
        source_field_path: 'pages[0].lines[1]',
        provider_span_start: name_start,
        provider_span_end: name_end
      )
      expect(block.dig(:reference_pricing_candidate, :validation_state)).to eq('ambiguous')
      expect(block.dig(:reference_pricing_candidate, :rejection_reasons)).to eq([ 'ambiguous_tax_inclusion' ])
      expect(block.dig(:printed_line_total, :amount)).to eq('600')
    end

    missing_price = result.deep_dup
    missing_price.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject').delete('Price')
    duplicate_destination = result.deep_dup
    duplicate_destination.dig('documents', 0, 'fields', 'Items', 'valueArray') << structured_item.deep_dup

    aggregate_failures do
      [ missing_price, duplicate_destination ].each do |analyze_result|
        expect(described_class.call(
          analyze_result:,
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        )).to eq([])
      end
    end
  end

  it 'fails closed for mismatches, ordinary discounts, packages, and summary-only totals' do
    cases = [
      [ '例示品A', '税込 498円/100g', '計量 342g', '1,704円' ],
      [ '例示品A', '税込 498円/100g', '計量 342g', '1703' ],
      [ '例示品A', '税込 498円/100g', '通常値引 10円', '計量 342g', '1,703円' ],
      [ '例示品A 2袋入り', '税込 498円/100g', '計量 342g', '1,703円' ],
      [ '例示品A', '税込 498円/100g', '計量 342g', '合計 1,703円' ],
      [ '架空店舗A', '税込 498円/100g', '計量 342g', '1,703円' ]
    ]

    cases.each do |block_lines|
      expect(extract([ 'HEADER', *block_lines, '合計 1,703円' ])).to eq([])
    end
  end

  it 'rejects malformed spans, polygons, and a horizontally swapped column cell' do
    lines = [
      'HEADER',
      '例示給油商品D',
      '単価(円/L) 数量(L) 金額(円)',
      '169',
      '49.80',
      '8,416',
      '合計 8,416円'
    ]
    layout = {
      2 => { left: 20, width: 230, word_lefts: [ 20, 100, 170 ] },
      3 => { left: 100, top: 86, width: 30 },
      4 => { left: 20, top: 86, width: 50 },
      5 => { left: 170, top: 86, width: 50 }
    }
    malformed_span = synthetic_analyze_result(lines)
    malformed_span.dig('pages', 0, 'lines', 3, 'spans', 0)['length'] = -1
    malformed_reference_span = synthetic_analyze_result(lines)
    malformed_reference_span.dig('pages', 0, 'lines', 2, 'spans', 0)['length'] = -1
    malformed_polygon = synthetic_analyze_result(lines)
    malformed_polygon.dig('pages', 0, 'lines', 3)['polygon'] = [ 20, 20, 30 ]
    distant_layout = {
      2 => { left: 20, top: 100, width: 230, word_lefts: [ 20, 100, 170 ] },
      3 => { left: 20, top: 124, width: 30 },
      4 => { left: 100, top: 124, width: 50 },
      5 => { left: 170, top: 124, width: 50 }
    }
    reversed_vertical_layout = {
      2 => { left: 20, top: 100, width: 230, word_lefts: [ 20, 100, 170 ] },
      3 => { left: 20, top: 86, width: 30 },
      4 => { left: 100, top: 86, width: 50 },
      5 => { left: 170, top: 86, width: 50 }
    }

    aggregate_failures do
      expect(extract(lines, layout:)).to eq([])
      expect(extract(lines, layout: distant_layout)).to eq([])
      expect(extract(lines, layout: reversed_vertical_layout)).to eq([])
      [ malformed_span, malformed_reference_span, malformed_polygon ].each do |result|
        expect(described_class.call(
          analyze_result: result,
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        )).to eq([])
      end
    end
  end

  it 'rejects multiple provider documents and malformed provider item collections' do
    multiple_documents = synthetic_analyze_result([
      'HEADER', '例示品A', '税込 120円/L', '計量 2.5L', '300円', '合計 300円'
    ])
    multiple_documents['documents'] << multiple_documents['documents'].sole.deep_dup
    malformed_items = synthetic_analyze_result([
      'HEADER', '例示品A', '税込 120円/L', '計量 2.5L', '300円', '合計 300円'
    ])
    malformed_items.dig('documents', 0, 'fields', 'Items')['valueArray'] = {}

    aggregate_failures do
      [ multiple_documents, malformed_items ].each do |result|
        expect(described_class.call(
          analyze_result: result,
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        )).to eq([])
      end
    end
  end

  it 'uses the injected profile vocabulary instead of hardcoded receipt terms' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_item_layout_purchased_quantity_line_pattern)
      .and_return(/\APURCHASE (?<quantity>[0-9.]+)(?<unit>[A-Za-z]+)\z/)
    allow(profile).to receive(:ocr_reference_pricing_item_layout_printed_total_line_pattern)
      .and_return(/\AITEM_TOTAL (?<amount>[0-9]+)\z/)

    custom = extract(
      [ 'HEADER', '例示品A', '税込 120円/L', 'PURCHASE 2.5L', 'ITEM_TOTAL 300', '合計 300円' ],
      profile:
    )
    original = extract(
      [ 'HEADER', '例示品A', '税込 120円/L', '計量 2.5L', '300円', '合計 300円' ],
      profile:
    )

    aggregate_failures do
      expect(custom).to contain_exactly(include(source_kind: 'azure_item_layout'))
      expect(original).to eq([])
    end
  end

  it 'uses injected profile vocabulary for every focused layout shape' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_item_layout_applied_unit_price_line_pattern)
      .and_return(/\AAPPLIED [0-9.]+円\/[A-Za-z]+\z/)
    allow(profile).to receive(:ocr_reference_pricing_item_layout_purchased_quantity_line_pattern)
      .and_return(/\APURCHASE (?<quantity>[0-9.]+)(?<unit>[A-Za-z]+)\z/)
    allow(profile).to receive(:ocr_reference_pricing_item_layout_purchased_quantity_label_line_pattern)
      .and_return(/\ALOAD\z/)
    allow(profile).to receive(:ocr_reference_pricing_item_layout_printed_total_line_pattern)
      .and_return(/\AITEM_TOTAL (?<amount>[0-9]+)\z/)
    allow(profile).to receive(:ocr_reference_pricing_item_layout_column_header_pattern)
      .and_return(
        /\A(?<price_heading>PRICE\((?<reference_unit>[A-Za-z]+)\)) (?<quantity_heading>QTY\((?<purchased_unit>[A-Za-z]+)\)) (?<total_heading>ITEM)\z/
      )
    allow(profile).to receive(:ocr_reference_pricing_item_layout_per_unit_discount_note_pattern)
      .and_return(/\ABENEFIT [0-9.]+円\/(?:(?<basis_quantity>[0-9.]+))?(?<unit>[A-Za-z]+)\z/)

    applied = extract(
      [
        'HEADER', '例示品A', 'APPLIED 160円/L', 'BENEFIT 3円/L',
        'PURCHASE 20.74L', 'ITEM_TOTAL 3318', '合計 3,318円'
      ],
      profile:
    )
    separated = extract(
      [ 'HEADER', '例示品B', '税込 120円/500ml', 'LOAD', '1.5L', 'ITEM_TOTAL 360', '合計 360円' ],
      profile:
    )
    column_lines = [
      'HEADER', '例示品C', 'PRICE(L) QTY(L) ITEM', '169', '49.80', '8416', '合計 8,416円'
    ]
    column_layout = {
      2 => { left: 20, width: 230, word_lefts: [ 20, 100, 170 ] },
      3 => { left: 20, top: 86, width: 30 },
      4 => { left: 100, top: 86, width: 50 },
      5 => { left: 170, top: 86, width: 50 }
    }
    column = extract(column_lines, layout: column_layout, profile:)
    original = extract(
      [ 'HEADER', '例示品D', '税込 120円/L', '計量 2.5L', '300円', '合計 300円' ],
      profile:
    )

    aggregate_failures do
      expect(applied).to contain_exactly(include(source_kind: 'azure_item_layout'))
      expect(separated).to contain_exactly(include(source_kind: 'azure_item_layout'))
      expect(column).to contain_exactly(include(source_kind: 'azure_item_layout'))
      expect(original).to eq([])
    end
  end
end
