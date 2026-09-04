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

  def structured_table_item(
    result,
    description_line_index:,
    product_code_line_index: nil,
    price_line_index:,
    quantity_line_index:,
    total_line_index:,
    price_amount:,
    quantity_amount:,
    quantity_unit:,
    total_amount:
  )
    page_lines = result.dig('pages', 0, 'lines')
    description = page_lines.fetch(description_line_index)
    price = page_lines.fetch(price_line_index)
    quantity = page_lines.fetch(quantity_line_index)
    total = page_lines.fetch(total_line_index)
    parent_start = description.dig('spans', 0, 'offset')
    parent_end = total.dig('spans', 0, 'offset') + total.dig('spans', 0, 'length')
    content = result.fetch('content')
    field = lambda do |line, value|
      {
        'content' => line.fetch('content'),
        'spans' => line.fetch('spans').deep_dup
      }.merge(value)
    end
    currency = lambda do |amount|
      { 'valueCurrency' => { 'currencyCode' => 'JPY', 'currencySymbol' => '円', 'amount' => amount } }
    end

    value_object = {
      'Description' => field.call(description, 'valueString' => description.fetch('content')),
      'Price' => field.call(price, currency.call(price_amount)),
      'Quantity' => field.call(quantity, 'valueNumber' => quantity_amount),
      'QuantityUnit' => field.call(quantity, 'valueString' => quantity_unit),
      'TotalPrice' => field.call(total, currency.call(total_amount))
    }
    if product_code_line_index
      product_code = page_lines.fetch(product_code_line_index)
      value_object['ProductCode'] = field.call(product_code, 'valueString' => product_code.fetch('content'))
    end

    {
      'content' => content[parent_start...parent_end],
      'spans' => [ { 'offset' => parent_start, 'length' => parent_end - parent_start } ],
      'valueObject' => value_object
    }
  end

  def shared_basis_table_result(lines:, layout:, rows:)
    result = synthetic_analyze_result(lines, layout:)
    items = rows.map do |row|
      structured_table_item(result, **row)
    end
    result.dig('documents', 0, 'fields', 'Items')['valueArray'] = items
    result
  end

  def single_shared_basis_table_result(
    header: '番号 100g当り(円) 重量(?) 金額(円)',
    before_name: [],
    name: '例示素材A',
    between_name_and_price: [],
    price: '320円',
    quantity: '250g',
    total: '800円',
    price_amount: 320,
    quantity_amount: 250,
    quantity_unit: 'g',
    total_amount: 800,
    cell_lefts: [ 70, 170, 240 ],
    header_word_lefts: [ 20, 70, 170, 240 ],
    header_width: 280
  )
    name_index = 2 + before_name.size
    price_index = name_index + between_name_and_price.size + 1
    quantity_index = price_index + 1
    total_index = quantity_index + 1
    row_top = 20 + (price_index * 22)
    lines = [
      '架空表形式店',
      header,
      *before_name,
      name,
      *between_name_and_price,
      price,
      quantity,
      total,
      "小計 #{total}"
    ]
    layout = {
      1 => { left: 20, width: header_width, word_lefts: header_word_lefts },
      price_index => { left: cell_lefts.fetch(0), top: row_top },
      quantity_index => { left: cell_lefts.fetch(1), top: row_top },
      total_index => { left: cell_lefts.fetch(2), top: row_top }
    }

    shared_basis_table_result(
      lines:,
      layout:,
      rows: [
        {
          description_line_index: name_index,
          product_code_line_index: between_name_and_price.one? ? name_index + 1 : nil,
          price_line_index: price_index,
          quantity_line_index: quantity_index,
          total_line_index: total_index,
          price_amount:,
          quantity_amount:,
          quantity_unit:,
          total_amount:
        }
      ]
    )
  end

  def multi_row_shared_basis_table_result(count:)
    lines = [ '架空表形式店', '番号 100g当り(円) 重量(?) 金額(円)' ]
    layout = { 1 => { left: 20, width: 280, word_lefts: [ 20, 70, 170, 240 ] } }
    rows = count.times.map do |index|
      name_index = lines.size
      lines.concat([ "例示素材#{index}", '200円', '250g', '500円' ])
      row_top = 70 + (index * 20)
      layout.merge!(
        name_index => { left: 20, top: row_top },
        name_index + 1 => { left: 100, top: row_top },
        name_index + 2 => { left: 170, top: row_top },
        name_index + 3 => { left: 240, top: row_top }
      )
      {
        description_line_index: name_index,
        price_line_index: name_index + 1,
        quantity_line_index: name_index + 2,
        total_line_index: name_index + 3,
        price_amount: 200,
        quantity_amount: 250,
        quantity_unit: 'g',
        total_amount: 500
      }
    end
    lines << "小計 #{count * 500}円"

    shared_basis_table_result(lines:, layout:, rows:)
  end

  def translate_line_geometry(result, line_index, x: 0, y: 0)
    line = result.dig('pages', 0, 'lines', line_index)
    span = line.fetch('spans').sole
    entries = [ line ] + result.dig('pages', 0, 'words').select do |word|
      word_span = word.fetch('span')
      word_span.fetch('offset') >= span.fetch('offset') &&
        word_span.fetch('offset') + word_span.fetch('length') <= span.fetch('offset') + span.fetch('length')
    end
    entries.each do |entry|
      entry['polygon'] = entry.fetch('polygon').each_slice(2).flat_map do |left, top|
        [ left + x, top + y ]
      end
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

  it 'keeps a standalone at-mark per-unit discount note bound to the applied price' do
    block = extract([
      '架空給油所A',
      '例示給油商品A',
      '特典適用後単価 160円/L',
      '@3円/L引',
      '給油量 20.74L',
      '金額 3,318円',
      '合計 3,318円'
    ]).sole

    aggregate_failures do
      expect(block).to include(
        per_unit_discount_note_present: true,
        owned_line_indexes: [ 1, 2, 3, 4, 5 ]
      )
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

  it 'binds one exact shared reference basis to one structured row without trusting its quantity heading unit' do
    result = single_shared_basis_table_result(
      before_name: [ '外税', '8.00%' ],
      between_name_and_price: [ '00000001' ],
      quantity: '0.25kg',
      quantity_amount: 0.25,
      quantity_unit: 'kg'
    )

    block = described_class.call(
      analyze_result: result,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    ).sole

    aggregate_failures do
      expect(block).to include(
        destination_kind: 'azure_structured_item',
        structured_item_index: 0,
        name_line_index: 4,
        reference_line_index: 6,
        purchased_quantity_line_indexes: [ 7 ],
        printed_total_line_index: 8,
        owned_line_indexes: [ 1, 4, 5, 6, 7, 8 ]
      )
      expect(block.dig(:reference_pricing_candidate, :validation_state)).to eq('ambiguous')
      expect(block.dig(:reference_pricing_candidate, :rejection_reasons)).to eq([ 'ambiguous_tax_inclusion' ])
      expect(block.dig(:reference_pricing_candidate, :reference_quantity, :evidence)).to include(
        source_field_path: 'pages[0].lines[1]',
        line_index: 1
      )
      expect(block.dig(:reference_pricing_candidate, :purchased_quantity, :evidence)).to include(
        source_field_path: 'pages[0].lines[7]',
        line_index: 7
      )
      expect_reference_source(
        block,
        price: '320',
        basis: '100',
        basis_unit: 'gram',
        purchased: '0.25',
        purchased_unit: 'kilogram'
      )
    end
  end

  it 'reuses one exact shared basis for bounded ordered structured rows' do
    result = multi_row_shared_basis_table_result(count: 2)

    blocks = described_class.call(
      analyze_result: result,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )

    aggregate_failures do
      expect(blocks.map { |block| block[:structured_item_index] }).to eq([ 0, 1 ])
      expect(blocks.map { |block| block.dig(:reference_pricing_candidate, :reference_quantity, :amount) }).to eq(%w[100 100])
      expect(blocks.map { |block| block.dig(:reference_pricing_candidate, :purchased_quantity, :amount) }).to eq(%w[250 250])
      expect(blocks.map { |block| block.dig(:printed_line_total, :amount) }).to eq(%w[500 500])
    end
  end

  it 'fails closed for ambiguous shared headers, unsafe rows, malformed ownership, and invalid table geometry' do
    formula_mismatch = single_shared_basis_table_result(total: '801円', total_amount: 801)
    dimension_mismatch = single_shared_basis_table_result(quantity: '250ml', quantity_unit: 'ml')
    incomplete = single_shared_basis_table_result
    incomplete.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject').delete('QuantityUnit')
    overlapping = single_shared_basis_table_result
    overlapping.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject', 'Quantity', 'spans', 0)
      .replace(overlapping.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject', 'Price', 'spans', 0))
    swapped = single_shared_basis_table_result(cell_lefts: [ 170, 70, 240 ])
    malformed_polygon = single_shared_basis_table_result
    malformed_polygon.dig('pages', 0, 'lines', 4)['polygon'] = [ 1, 2, 3 ]
    package = single_shared_basis_table_result(name: '例示素材A 2袋入り')
    duplicate_item = single_shared_basis_table_result
    duplicate_item.dig('documents', 0, 'fields', 'Items', 'valueArray') <<
      duplicate_item.dig('documents', 0, 'fields', 'Items', 'valueArray', 0).deep_dup
    malformed_span = single_shared_basis_table_result
    malformed_span.dig('pages', 0, 'lines', 4, 'spans', 0)['length'] = -1
    cross_page = single_shared_basis_table_result
    cross_page['pages'] << cross_page.fetch('pages').sole.deep_dup
    multiple_basis = single_shared_basis_table_result(
      header: '番号 100g当り(円) 1kg当り(円) 重量(?) 金額(円)',
      header_word_lefts: [ 20, 60, 125, 195, 255 ],
      header_width: 320
    )
    adjacent = single_shared_basis_table_result(before_name: [ '隣接素材B' ])
    discount = single_shared_basis_table_result(before_name: [ '通常値引 10円' ])
    duplicate_header = single_shared_basis_table_result(
      before_name: [ '番号 100g当り(円) 重量(?) 金額(円)' ]
    )
    cross_item_field = multi_row_shared_basis_table_result(count: 2)
    first_fields = cross_item_field.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject')
    second_price = cross_item_field.dig(
      'documents', 0, 'fields', 'Items', 'valueArray', 1, 'valueObject', 'Price'
    )
    first_fields.fetch('Price')['spans'] = second_price.fetch('spans').deep_dup
    slash_context = single_shared_basis_table_result(before_name: [ 'opaque/context' ])
    numeric_context = single_shared_basis_table_result(before_name: [ '12345' ])
    competing_basis_context = single_shared_basis_table_result(before_name: [ '100g/1kg' ])
    unrecognized_context = single_shared_basis_table_result(before_name: [ '---' ])
    displaced_name = single_shared_basis_table_result
    translate_line_geometry(displaced_name, 2, x: 240)
    distant_header_row = single_shared_basis_table_result
    distant_header_row.dig('pages', 0)['height'] = 1_000
    (2..5).each { |line_index| translate_line_geometry(distant_header_row, line_index, y: 300) }
    reversed_name_cells = single_shared_basis_table_result
    (3..5).each { |line_index| translate_line_geometry(reversed_name_cells, line_index, y: -60) }
    distant_rows = multi_row_shared_basis_table_result(count: 2)
    distant_rows.dig('pages', 0)['height'] = 1_000
    (6..9).each { |line_index| translate_line_geometry(distant_rows, line_index, y: 300) }
    reversed_rows = multi_row_shared_basis_table_result(count: 2)
    (6..9).each { |line_index| translate_line_geometry(reversed_rows, line_index, y: -100) }
    displaced_second_name = multi_row_shared_basis_table_result(count: 2)
    translate_line_geometry(displaced_second_name, 6, x: 240)
    displaced_second_cells = multi_row_shared_basis_table_result(count: 2)
    (7..9).each { |line_index| translate_line_geometry(displaced_second_cells, line_index, y: 80) }

    aggregate_failures do
      {
        formula_mismatch:,
        dimension_mismatch:,
        incomplete:,
        overlapping:,
        swapped:,
        malformed_polygon:,
        package:,
        duplicate_item:,
        malformed_span:,
        cross_page:,
        multiple_basis:,
        adjacent:,
        discount:,
        duplicate_header:,
        cross_item_field:,
        slash_context:,
        numeric_context:,
        competing_basis_context:,
        unrecognized_context:,
        displaced_name:,
        distant_header_row:,
        reversed_name_cells:,
        distant_rows:,
        reversed_rows:,
        displaced_second_name:,
        displaced_second_cells:
      }.each do |name, result|
        expect(described_class.call(
          analyze_result: result,
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        )).to eq([]), name.to_s
      end
    end
  end

  it 'accepts only the bounded context, row-line, and row-count transition values' do
    cases = {
      context_three: single_shared_basis_table_result(before_name: [ '外税', '8.00%', '10.00%' ]),
      context_four: single_shared_basis_table_result(before_name: [ '外税', '8.00%', '10.00%', '5.00%' ]),
      row_five: single_shared_basis_table_result(between_name_and_price: [ '00000001' ]),
      row_six: single_shared_basis_table_result(between_name_and_price: %w[00000001 00000002]),
      rows_twenty: multi_row_shared_basis_table_result(count: 20),
      rows_twenty_one: multi_row_shared_basis_table_result(count: 21)
    }

    results = cases.transform_values do |result|
      described_class.call(
        analyze_result: result,
        profile: ReceiptAnalysisProfiles.fetch('JPN'),
        projection: ReceiptAmountService.method(:reference_item_extension_projection)
      )
    end

    aggregate_failures do
      expect(results.fetch(:context_three).size).to eq(1)
      expect(results.fetch(:context_four)).to eq([])
      expect(results.fetch(:row_five).size).to eq(1)
      expect(results.fetch(:row_six)).to eq([])
      expect(results.fetch(:rows_twenty).size).to eq(20)
      expect(results.fetch(:rows_twenty_one)).to eq([])
    end
  end

  it 'uses injected shared-header vocabulary instead of hardcoded Japanese labels' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_item_layout_shared_basis_header_pattern)
      .and_return(
        /\ABASIS (?<price_heading>(?<reference_basis>(?<reference_quantity>[0-9]+)(?<reference_unit>[A-Za-z]+))) (?<quantity_heading>LOAD) (?<total_heading>SUM)\z/
      )
    result = single_shared_basis_table_result(header: 'BASIS 100g LOAD SUM')

    custom = described_class.call(
      analyze_result: result,
      profile:,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
    original_result = single_shared_basis_table_result
    original = described_class.call(
      analyze_result: original_result,
      profile:,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )

    aggregate_failures do
      expect(custom).to contain_exactly(include(destination_kind: 'azure_structured_item'))
      expect(original).to eq([])
    end
  end

  it 'uses only the injected positive header-context vocabulary' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_item_layout_shared_basis_context_line_pattern)
      .and_return(/\AALLOWED-CONTEXT\z/)

    accepted = described_class.call(
      analyze_result: single_shared_basis_table_result(before_name: [ 'ALLOWED-CONTEXT' ]),
      profile:,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
    rejected = described_class.call(
      analyze_result: single_shared_basis_table_result(before_name: [ '外税' ]),
      profile:,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )

    aggregate_failures do
      expect(accepted.size).to eq(1)
      expect(rejected).to eq([])
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
