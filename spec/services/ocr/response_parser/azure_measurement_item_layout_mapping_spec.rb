require 'rails_helper'

RSpec.describe 'Azure measurement item-layout mapping' do
  def text_element_length(value)
    value.scan(/\X/).length
  end

  def synthetic_response(lines, layout: {}, items: [], extra_fields: {})
    content = lines.join("\n")
    cursor = 0
    words = []
    page_lines = lines.each_with_index.map do |line, line_index|
      geometry = layout.fetch(line_index, {})
      line_length = text_element_length(line)
      left = geometry.fetch(:left, 20)
      top = geometry.fetch(:top, 20 + (line_index * 22))
      width = geometry.fetch(:width, [ line_length * 10, 30 ].max)
      height = geometry.fetch(:height, 16)
      word_lefts = geometry[:word_lefts]

      line.to_enum(:scan, /\S+/).each_with_index do |word, word_index|
        match = Regexp.last_match
        prefix = line[0...match.begin(0)]
        word_left = word_lefts&.fetch(word_index) || left + (text_element_length(prefix) * 10)
        word_width = [ text_element_length(word) * 10, 10 ].max
        words << {
          'content' => word,
          'polygon' => [
            word_left, top, word_left + word_width, top,
            word_left + word_width, top + height, word_left, top + height
          ],
          'confidence' => 0.99,
          'span' => {
            'offset' => cursor + text_element_length(prefix),
            'length' => text_element_length(word)
          }
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

    fields = extra_fields.merge(
      'Items' => { 'type' => 'array', 'valueArray' => items }
    )
    summary_index = lines.rindex { |line| line.match?(/\A合計/) }
    if summary_index
      line = page_lines.fetch(summary_index)
      amount = line.fetch('content').scan(/\d[\d,]*/).sole
      relative_offset = line.fetch('content').index(amount)
      fields['Total'] = {
        'type' => 'currency',
        'content' => amount,
        'spans' => [
          {
            'offset' => line.dig('spans', 0, 'offset') + text_element_length(
              line.fetch('content')[0...relative_offset]
            ),
            'length' => text_element_length(amount)
          }
        ],
        'valueCurrency' => {
          'amount' => amount.delete(',').to_i,
          'currencyCode' => 'JPY'
        }
      }
    end

    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'apiVersion' => '2024-11-30',
        'modelId' => 'prebuilt-receipt',
        'stringIndexType' => 'textElements',
        'content' => content,
        'pages' => [
          {
            'pageNumber' => 1,
            'width' => 320,
            'height' => [ 140, lines.length * 30 ].max,
            'unit' => 'pixel',
            'words' => words,
            'lines' => page_lines
          }
        ],
        'documents' => [
          {
            'docType' => 'receipt.retailMeal',
            'fields' => fields
          }
        ]
      }
    }
  end

  def parse(response)
    Ocr::ResponseParser.new(
      response:,
      provider: 'azure_document_intelligence',
      profile: ReceiptAnalysisProfiles.fetch('JPN')
    ).call
  end

  def line_span(response, line_index)
    response.dig('analyzeResult', 'pages', 0, 'lines', line_index, 'spans', 0)
  end

  def structured_item(
    response,
    name_line_index:,
    reference_line_index:,
    quantity_line_index:,
    total_line_index:,
    reference_amount: nil,
    quantity: nil,
    quantity_unit: nil,
    total_amount:
  )
    content = response.dig('analyzeResult', 'content')
    name_line = response.dig('analyzeResult', 'pages', 0, 'lines', name_line_index)
    reference_line = response.dig('analyzeResult', 'pages', 0, 'lines', reference_line_index)
    quantity_line = response.dig('analyzeResult', 'pages', 0, 'lines', quantity_line_index)
    total_line = response.dig('analyzeResult', 'pages', 0, 'lines', total_line_index)
    first_span = line_span(response, name_line_index)
    last_span = line_span(response, total_line_index)
    parent_start = first_span.fetch('offset')
    parent_end = last_span.fetch('offset') + last_span.fetch('length')
    value_object = {
      'Description' => {
        'content' => name_line.fetch('content'),
        'valueString' => name_line.fetch('content'),
        'spans' => [ first_span.deep_dup ]
      },
      'TotalPrice' => {
        'content' => total_line.fetch('content'),
        'valueCurrency' => { 'amount' => total_amount, 'currencyCode' => 'JPY' },
        'spans' => [ line_span(response, total_line_index).deep_dup ]
      }
    }
    if reference_amount
      value_object['Price'] = {
        'content' => reference_line.fetch('content'),
        'valueCurrency' => { 'amount' => reference_amount, 'currencyCode' => 'JPY' },
        'spans' => [ line_span(response, reference_line_index).deep_dup ]
      }
    end
    if quantity
      value_object['Quantity'] = {
        'content' => quantity_line.fetch('content'),
        'valueNumber' => quantity,
        'spans' => [ line_span(response, quantity_line_index).deep_dup ]
      }
    end
    if quantity_unit
      unit_start = quantity_line.fetch('content').rindex(quantity_unit)
      quantity_span = line_span(response, quantity_line_index)
      value_object['QuantityUnit'] = {
        'content' => quantity_unit,
        'valueString' => quantity_unit,
        'spans' => [
          {
            'offset' => quantity_span.fetch('offset') + text_element_length(
              quantity_line.fetch('content')[0...unit_start]
            ),
            'length' => text_element_length(quantity_unit)
          }
        ]
      }
    end

    {
      'content' => content.scan(/\X/)[parent_start...parent_end].join,
      'spans' => [ { 'offset' => parent_start, 'length' => parent_end - parent_start } ],
      'valueObject' => value_object
    }
  end

  def base_layout_response
    synthetic_response([
      '架空量売店A',
      '例示量売品A',
      '税込 498円/100g',
      '計量 342g',
      '1,703円',
      '合計 1,703円'
    ])
  end

  def modes(candidate)
    candidate.fetch(:options).map { |option| option.fetch(:pricing_source_kind) }
  end

  it 'builds one diagnostic layout item while masking every owned line from receipt fallbacks' do
    result = parse(base_layout_response)
    item = result.dig(:candidates, :items).sole
    reference = result.dig(:candidates, :reference_pricing_candidates).sole
    mode_candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole

    aggregate_failures do
      expect(item).to include(
        raw_text: '例示量売品A',
        price: '498',
        quantity: '342',
        quantity_unit_code: 'gram',
        line_total: 1703,
        original_line_total: 1703
      )
      expect(item[:ocr_item_identity]).to start_with('azure_item_layout_item_')
      expect(item.keys).not_to include(
        :pricing_source_kind,
        :reference_price_amount,
        :reference_quantity,
        :reference_quantity_unit_code,
        :reference_price_tax_inclusion
      )
      expect(reference).to include(
        source_kind: 'azure_item_layout',
        validation_state: 'valid',
        reference_price_tax_inclusion: 'gross'
      )
      expect(modes(mode_candidate)).to eq([ 'explicit_line_total' ])
      expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      expect(result.dig(:candidates, :subtotal_amount)).to be_nil
      expect(result.dig(:candidates, :total_amount)).to eq(1703)
    end
  end

  it 'keeps the same layout-only result when Azure omits the Items field' do
    response = base_layout_response
    response.dig('analyzeResult', 'documents', 0, 'fields').delete('Items')

    result = parse(response)

    aggregate_failures do
      expect(result.dig(:candidates, :items)).to contain_exactly(
        include(raw_text: '例示量売品A', line_total: 1703)
      )
      expect(result.dig(:candidates, :reference_pricing_candidates)).to contain_exactly(
        include(source_kind: 'azure_item_layout')
      )
      expect(result.dig(:candidates, :item_calculation_mode_candidates)).to contain_exactly(
        include(options: [ include(pricing_source_kind: 'explicit_line_total') ])
      )
    end
  end

  it 'supplements one exact structured destination without duplicating its item' do
    response = base_layout_response
    item = structured_item(
      response,
      name_line_index: 1,
      reference_line_index: 2,
      quantity_line_index: 3,
      total_line_index: 4,
      total_amount: 1703
    )
    response.dig('analyzeResult', 'documents', 0, 'fields', 'Items')['valueArray'] = [ item ]

    result = parse(response)
    reference = result.dig(:candidates, :reference_pricing_candidates).sole

    aggregate_failures do
      expect(result.dig(:candidates, :items)).to contain_exactly(
        include(raw_text: '例示量売品A', line_total: 1703)
      )
      expect(result.dig(:candidates, :item_calculation_mode_candidates)).to contain_exactly(
        include(item_index: 0, options: [ include(pricing_source_kind: 'explicit_line_total') ])
      )
      expect(reference).to include(source_kind: 'azure_item_layout')
      expect(reference[:candidate_id]).to start_with('azure_item_layout_')
    end
  end

  it 'replaces one exact same-slot column misparse instead of appending a second item' do
    lines = [
      '架空給油所B',
      '例示給油商品B',
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
    response = synthetic_response(lines, layout:)
    cell_start = line_span(response, 3).fetch('offset')
    cell_end = line_span(response, 5).then { |span| span.fetch('offset') + span.fetch('length') }
    response.dig('analyzeResult', 'documents', 0, 'fields', 'Items')['valueArray'] = [
      {
        'content' => response.dig('analyzeResult', 'content').scan(/\X/)[cell_start...cell_end].join,
        'spans' => [ { 'offset' => cell_start, 'length' => cell_end - cell_start } ],
        'valueObject' => {
          'Description' => {
            'content' => '169',
            'valueString' => '169',
            'spans' => [ line_span(response, 3).deep_dup ]
          },
          'Price' => {
            'content' => '49.80',
            'valueCurrency' => { 'amount' => 49.8, 'currencyCode' => 'JPY' },
            'spans' => [ line_span(response, 4).deep_dup ]
          },
          'TotalPrice' => {
            'content' => '8,416',
            'valueCurrency' => { 'amount' => 8416, 'currencyCode' => 'JPY' },
            'spans' => [ line_span(response, 5).deep_dup ]
          }
        }
      }
    ]

    result = parse(response)

    aggregate_failures do
      expect(result.dig(:candidates, :items)).to contain_exactly(
        include(
          raw_text: '例示給油商品B',
          price: '169',
          quantity: '49.8',
          quantity_unit_code: 'liter',
          line_total: 8416
        )
      )
      expect(result.dig(:candidates, :reference_pricing_candidates)).to contain_exactly(
        include(source_kind: 'azure_item_layout')
      )
    end
  end

  it 'fails closed for a reference candidate when structured and layout values disagree' do
    response = base_layout_response
    item = structured_item(
      response,
      name_line_index: 1,
      reference_line_index: 2,
      quantity_line_index: 3,
      total_line_index: 4,
      total_amount: 1699
    )
    response.dig('analyzeResult', 'documents', 0, 'fields', 'Items')['valueArray'] = [ item ]

    result = parse(response)

    aggregate_failures do
      expect(result.dig(:candidates, :items).size).to eq(1)
      expect(result.dig(:candidates, :reference_pricing_candidates)).to eq([])
      expect(result.dig(:candidates, :item_calculation_mode_candidates)).to all(
        satisfy { |candidate| modes(candidate) == [ 'explicit_line_total' ] }
      )
    end
  end

  it 'does not fabricate items when more than one layout-only block is present' do
    response = synthetic_response([
      '架空量売店C',
      '例示量売品C',
      '税込 498円/100g',
      '計量 342g',
      '1,703円',
      '例示量売品D',
      '税込 120円/500ml',
      '計量 1.5L',
      '360円',
      '合計 2,063円'
    ])

    result = parse(response)

    aggregate_failures do
      expect(result.dig(:candidates, :items)).to eq([])
      expect(result.dig(:candidates, :reference_pricing_candidates)).to eq([])
      expect(result.dig(:candidates, :item_calculation_mode_candidates)).to eq([])
    end
  end

  it 'keeps structured reference candidates authoritative and preserves the line-group fallback' do
    structured_response = base_layout_response
    structured = structured_item(
      structured_response,
      name_line_index: 1,
      reference_line_index: 2,
      quantity_line_index: 3,
      total_line_index: 4,
      reference_amount: 498,
      quantity: 342,
      quantity_unit: 'g',
      total_amount: 1703
    )
    structured_response.dig(
      'analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray'
    ) << structured
    line_group_response = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_anonymized.json').read
    )

    structured_result = parse(structured_response)
    line_group_result = parse(line_group_response)

    aggregate_failures do
      expect(structured_result.dig(:candidates, :reference_pricing_candidates)).to contain_exactly(
        include(candidate_id: 'azure_items_0_reference_pricing', item_index: 0)
      )
      expect(structured_result.dig(:candidates, :items).size).to eq(1)
      expect(line_group_result.dig(:candidates, :reference_pricing_candidates)).to contain_exactly(
        include(source_kind: 'azure_line_group')
      )
      expect(line_group_result.dig(:candidates, :items)).to eq([])
    end
  end

  it 'does not leak a post-discount layout block into subtotal or adjustment authority' do
    response = synthetic_response([
      '架空給油所E',
      '例示給油商品E',
      '特典適用後単価 160円/L',
      '会員値引 3円/L引',
      '給油量 20.74L',
      '金額 3,318円',
      '合計 3,318円'
    ])

    result = parse(response)

    aggregate_failures do
      expect(result.dig(:candidates, :items).size).to eq(1)
      expect(result.dig(:candidates, :subtotal_amount)).to be_nil
      expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      expect(result.dig(:candidates, :total_amount)).to eq(3318)
    end
  end
end
