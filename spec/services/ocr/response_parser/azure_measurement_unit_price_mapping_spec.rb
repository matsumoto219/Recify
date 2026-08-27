require 'rails_helper'
require 'timeout'

RSpec.describe 'Azure structured measurement unit-price mapping' do
  POSITIVE_FIXTURE = 'ocr_azure_measurement_unit_price_positive_anonymized.json'
  NEGATIVE_FIXTURE = 'ocr_azure_measurement_unit_price_negative_anonymized.json'
  AZURE_MEASUREMENT_SOURCE_FIELDS = {
    reference_price: 'Price',
    reference_quantity: 'QuantityUnit',
    purchased_quantity: 'Quantity',
    printed_line_total: 'TotalPrice'
  }.freeze

  def fixture(name)
    JSON.parse(Rails.root.join('spec/fixtures/ocr', name).read)
  end

  def extract(items)
    Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items: items,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
  end

  def positive_cases
    fixture(POSITIVE_FIXTURE).fetch('cases')
  end

  def negative_cases
    fixture(NEGATIVE_FIXTURE).fetch('cases')
  end

  def utf16_slice(text, start_offset, end_offset)
    encoded = text.encode(Encoding::UTF_16LE)
    encoded.byteslice(start_offset * 2, (end_offset - start_offset) * 2).to_s
      .force_encoding(Encoding::UTF_16LE)
      .encode(Encoding::UTF_8)
  end

  def synthetic_response(item)
    content = item.fetch('content')
    cursor = 0
    lines = content.lines(chomp: true).map do |line|
      length = utf16_length(line)
      entry = {
        'content' => line,
        'spans' => [ { 'offset' => cursor, 'length' => length } ]
      }
      cursor += length + 1
      entry
    end

    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'apiVersion' => '2024-11-30',
        'modelId' => 'prebuilt-receipt',
        'stringIndexType' => 'utf16CodeUnit',
        'content' => content,
        'documents' => [
          {
            'docType' => 'receipt.retailMeal',
            'fields' => {
              'Items' => { 'type' => 'array', 'valueArray' => [ item ] }
            }
          }
        ],
        'pages' => [
          {
            'pageNumber' => 1,
            'lines' => lines
          }
        ]
      }
    }
  end

  def append_response_line(response, line)
    analyze_result = response.fetch('analyzeResult')
    offset = utf16_length(analyze_result.fetch('content')) + 1
    analyze_result['content'] = "#{analyze_result.fetch('content')}\n#{line}"
    analyze_result.dig('pages', 0, 'lines') << {
      'content' => line,
      'spans' => [ { 'offset' => offset, 'length' => utf16_length(line) } ]
    }
  end

  def utf16_length(value)
    value.encode(Encoding::UTF_16LE).bytesize / 2
  end

  def reindex_item(item, index_type:)
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type:)
    value_object = item.fetch('valueObject')
    fields = %w[Description Price Quantity TotalPrice].map { |name| value_object.fetch(name) }
    content = fields.map { |field| field.fetch('content') }.join("\n")
    byte_cursor = 0

    fields.each do |field|
      field_content = field.fetch('content')
      span = mapper.span_for_bytes(
        content,
        byte_offset: byte_cursor,
        byte_length: field_content.bytesize
      ).transform_keys(&:to_s)
      field['spans'] = [ span ]
      byte_cursor += field_content.bytesize + 1
    end
    quantity = value_object.fetch('Quantity')
    unit = value_object.fetch('QuantityUnit')
    quantity_byte_offset = content.b.index(quantity.fetch('content').b)
    unit_byte_offset = quantity.fetch('content').b.index(unit.fetch('content').b)
    unit['spans'] = [
      mapper.span_for_bytes(
        content,
        byte_offset: quantity_byte_offset + unit_byte_offset,
        byte_length: unit.fetch('content').bytesize
      ).transform_keys(&:to_s)
    ]
    item.merge(
      'content' => content,
      'spans' => [ { 'offset' => 0, 'length' => mapper.length(content) } ]
    )
  end

  def structured_item(description:, price:, quantity:, unit:, total:)
    content = [ description, price.fetch(:content), quantity.fetch(:content), total.fetch(:content) ].join("\n")
    description_offset = 0
    price_offset = description.length + 1
    quantity_offset = price_offset + price.fetch(:content).length + 1
    total_offset = quantity_offset + quantity.fetch(:content).length + 1
    unit_offset = quantity_offset + quantity.fetch(:content).index(unit.fetch(:content))

    {
      'content' => content,
      'spans' => [ { 'offset' => 0, 'length' => content.encode(Encoding::UTF_16LE).bytesize / 2 } ],
      'confidence' => 0.99,
      'valueObject' => {
        'Description' => {
          'content' => description,
          'spans' => [ { 'offset' => description_offset, 'length' => description.length } ],
          'valueString' => description
        },
        'Price' => {
          'content' => price.fetch(:content),
          'spans' => [ { 'offset' => price_offset, 'length' => price.fetch(:content).length } ],
          'valueCurrency' => { 'amount' => price.fetch(:amount), 'currencyCode' => 'JPY' }
        },
        'Quantity' => {
          'content' => quantity.fetch(:content),
          'spans' => [ { 'offset' => quantity_offset, 'length' => quantity.fetch(:content).length } ],
          'valueNumber' => quantity.fetch(:amount)
        },
        'QuantityUnit' => {
          'content' => unit.fetch(:content),
          'spans' => [ { 'offset' => unit_offset, 'length' => unit.fetch(:content).length } ],
          'valueString' => unit.fetch(:value)
        },
        'TotalPrice' => {
          'content' => total.fetch(:content),
          'spans' => [ { 'offset' => total_offset, 'length' => total.fetch(:content).length } ],
          'valueCurrency' => { 'amount' => total.fetch(:amount), 'currencyCode' => 'JPY' }
        }
      }
    }
  end

  it 'maps four bounded measurement shapes to exact candidate components without mutating input' do
    positive_cases.each do |case_data|
      item = case_data.fetch('item')
      before = item.deep_dup
      expected = case_data.fetch('expected')
      candidate = extract([ item ]).sole

      aggregate_failures case_data.fetch('case_id') do
        expect(item).to eq(before)
        expect(candidate).to include(
          item_index: 0,
          validation_state: expected.fetch('validation_state'),
          rejection_reasons: expected.fetch('rejection_reasons'),
          reference_price_tax_inclusion: 'unknown',
          tax_inclusion_evidence: nil
        )
        expect(candidate[:reference_price]).to include(amount: expected.fetch('reference_price_amount'))
        expect(candidate[:reference_quantity]).to include(
          amount: expected.fetch('reference_quantity'),
          unit_code: expected.fetch('reference_unit_code'),
          unit_status: 'known',
          origin: 'implicit_per_unit'
        )
        expect(candidate[:purchased_quantity]).to include(
          amount: expected.fetch('purchased_quantity'),
          unit_code: expected.fetch('purchased_unit_code'),
          unit_status: 'known'
        )
        expect(candidate[:printed_line_total]).to include(amount: expected.fetch('printed_total'))
        expect(candidate[:corroboration]).to eq(
          exact_amount: {
            numerator: expected.fetch('exact_numerator'),
            denominator: expected.fetch('exact_denominator')
          },
          projected_amount: expected.fetch('projected_amount'),
          printed_line_total: expected.fetch('printed_total'),
          rounding_matches: expected.fetch('rounding_matches')
        )
        expect(candidate.keys).not_to include(
          :pricing_source_kind,
          :reference_price_amount,
          :reference_quantity_unit_code
        )
      end
    end
  end

  it 'maps textElements structured evidence without splitting emoji or combining sequences' do
    item = fixture('ocr_azure_item_calculation_reference_gross_anonymized.json')
      .dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray', 0)
      .deep_dup
    description = item.dig('valueObject', 'Description')
    description.merge!('content' => '検証😀品', 'valueString' => '検証😀品')
    item = reindex_item(item, index_type: 'textElements')
    prefix = "受付e\u0301\n"
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: 'textElements')
    prefix_length = mapper.length(prefix)
    [ item, *item.fetch('valueObject').values ].each do |component|
      component.fetch('spans').each { |span| span['offset'] += prefix_length }
    end
    response = synthetic_response(item)
    analyze_result = response.fetch('analyzeResult')
    analyze_result['stringIndexType'] = 'textElements'
    analyze_result['content'] = "#{prefix}#{item.fetch('content')}"
    cursor = 0
    analyze_result.dig('pages', 0)['lines'] = analyze_result.fetch('content').lines(chomp: true).map do |line|
      entry = {
        'content' => line,
        'spans' => [ { 'offset' => cursor, 'length' => mapper.length(line) } ]
      }
      cursor += mapper.length(line) + 1
      entry
    end

    result = Ocr::ResponseParser.new(response:, provider: :fixture).call
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole

    aggregate_failures do
      expect(candidate).to include(
        item_index: 0,
        validation_state: 'valid',
        rejection_reasons: [],
        reference_price_tax_inclusion: 'gross'
      )
      expect(candidate.dig(:reference_price, :amount)).to eq('498')
      expect(candidate.dig(:reference_quantity, :amount)).to eq('100')
      expect(candidate.dig(:purchased_quantity, :amount)).to eq('342')
      expect(result.dig(:candidates, :item_calculation_mode_candidates).sole).to include(
        string_index_type: 'textElements'
      )
    end
  end

  it 'fails closed when the provider index type is unsupported or the top-level content binding differs' do
    item = positive_cases.first.fetch('item').deep_dup
    unsupported = synthetic_response(item.deep_dup)
    unsupported.dig('analyzeResult')['stringIndexType'] = 'utf8Byte'
    mismatched = synthetic_response(item.deep_dup)
    mismatched.dig('analyzeResult')['content'] = "X#{mismatched.dig('analyzeResult', 'content')}"

    aggregate_failures do
      expect(Ocr::ResponseParser.new(
        response: unsupported,
        provider: :fixture
      ).call.dig(:candidates, :reference_pricing_candidates)).to eq([])
      expect(Ocr::ResponseParser.new(
        response: mismatched,
        provider: :fixture
      ).call.dig(:candidates, :reference_pricing_candidates)).to eq([])
    end
  end

  it 'does not treat an Azure Items Measurement component as the receipt Total' do
    item = positive_cases.first.fetch('item').deep_dup
    response = synthetic_response(item)
    summary_amount = item.dig('valueObject', 'TotalPrice', 'content')
    append_response_line(response, "合計 #{summary_amount}円")
    price = item.dig('valueObject', 'Price')
    price_digits = price.fetch('content').scan(/\d+/).sole
    price_offset = price.dig('spans', 0, 'offset') + price.fetch('content').index(price_digits)
    response.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = {
      'content' => price_digits,
      'spans' => [ { 'offset' => price_offset, 'length' => price_digits.length } ],
      'valueCurrency' => { 'amount' => price_digits.to_i, 'currencyCode' => 'JPY' }
    }

    result = Ocr::ResponseParser.new(response:, provider: :fixture).call

    aggregate_failures do
      expect(result.dig(:candidates, :reference_pricing_candidates).sole[:candidate_id]).to eq(
        'azure_items_0_reference_pricing'
      )
      expect(result.dig(:candidates, :total_amount)).to eq(summary_amount.to_i)
    end

    response.dig('analyzeResult', 'pages', 0, 'lines').pop
    result_without_summary = Ocr::ResponseParser.new(response:, provider: :fixture).call

    expect(result_without_summary.dig(:candidates, :total_amount)).to be_nil
  end

  it 'requires a bounded document Total to belong to an explicit receipt summary line' do
    item = positive_cases.first.fetch('item').deep_dup
    summary_amount = item.dig('valueObject', 'TotalPrice', 'content')
    base_response = synthetic_response(item)
    analyze_result = base_response.fetch('analyzeResult')
    header = 'SYNTH-HEADER 999'
    summary = "合計 #{summary_amount}円"
    append_response_line(base_response, header)
    append_response_line(base_response, summary)
    header_line = analyze_result.dig('pages', 0, 'lines', -2)
    header_amount_offset = header_line.dig('spans', 0, 'offset') + header.index('999')

    malformed_totals = [
      {
        'content' => '999',
        'spans' => [ { 'offset' => header_amount_offset, 'length' => 3 } ],
        'valueCurrency' => { 'amount' => 999, 'currencyCode' => 'JPY' }
      },
      {
        'content' => '999',
        'spans' => [ { 'offset' => header_amount_offset, 'length' => 0 } ],
        'valueCurrency' => { 'amount' => 999, 'currencyCode' => 'JPY' }
      }
    ]

    malformed_totals.each do |total|
      response = base_response.deep_dup
      response.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = total

      result = Ocr::ResponseParser.new(response:, provider: :fixture).call

      expect(result.dig(:candidates, :total_amount)).to eq(summary_amount.to_i)
    end
  end

  it 'does not trust a summary line without an exact provider span and top-level slice' do
    item = positive_cases.first.fetch('item').deep_dup
    response = synthetic_response(item)
    price = item.dig('valueObject', 'Price')
    price_digits = price.fetch('content').scan(/\d+/).sole
    price_offset = price.dig('spans', 0, 'offset') + price.fetch('content').index(price_digits)
    response.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = {
      'content' => price_digits,
      'spans' => [ { 'offset' => price_offset, 'length' => price_digits.length } ],
      'valueCurrency' => { 'amount' => price_digits.to_i, 'currencyCode' => 'JPY' }
    }
    response.dig('analyzeResult', 'pages', 0, 'lines') << { 'content' => '合計 999円' }

    result = Ocr::ResponseParser.new(response:, provider: :fixture).call

    expect(result.dig(:candidates, :total_amount)).to be_nil
  end

  it 'preserves an exact document Total owned by one explicit summary line' do
    item = positive_cases.first.fetch('item').deep_dup
    response = synthetic_response(item)
    summary_amount = item.dig('valueObject', 'TotalPrice', 'content')
    summary = "合計 #{summary_amount}円"
    append_response_line(response, summary)
    summary_line = response.dig('analyzeResult', 'pages', 0, 'lines').last
    amount_offset = summary_line.dig('spans', 0, 'offset') + summary.index(summary_amount)
    response.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = {
      'content' => summary_amount,
      'spans' => [ { 'offset' => amount_offset, 'length' => utf16_length(summary_amount) } ],
      'valueCurrency' => { 'amount' => summary_amount.to_i, 'currencyCode' => 'JPY' }
    }
    parser = Ocr::ResponseParser.new(response:, provider: :fixture)

    expect(parser).not_to receive(:extract_strict_summary_total_from_response)
    expect(parser.call.dig(:candidates, :total_amount)).to eq(summary_amount.to_i)
  end

  it 'fails closed from malformed or non-JPY structured Total ownership' do
    item = positive_cases.first.fetch('item').deep_dup
    response = synthetic_response(item)
    summary_amount = item.dig('valueObject', 'TotalPrice', 'content')
    summary = "合計 #{summary_amount}円"
    append_response_line(response, summary)
    summary_line = response.dig('analyzeResult', 'pages', 0, 'lines').last
    amount_offset = summary_line.dig('spans', 0, 'offset') + summary.index(summary_amount)
    total = {
      'content' => summary_amount,
      'spans' => [ { 'offset' => amount_offset, 'length' => utf16_length(summary_amount) } ],
      'valueCurrency' => { 'amount' => summary_amount.to_i, 'currencyCode' => 'JPY' }
    }

    [
      total.deep_merge('valueCurrency' => { 'amount' => summary_amount.to_i + 0.5 }),
      total.deep_merge('valueCurrency' => { 'currencyCode' => 'USD' }),
      total.deep_dup.tap { |value| value.fetch('spans').unshift(nil) }
    ].each do |invalid_total|
      invalid_response = response.deep_dup
      invalid_response.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = invalid_total
      parser = Ocr::ResponseParser.new(response: invalid_response, provider: :fixture)

      expect(parser).to receive(:extract_strict_summary_total_from_response).and_call_original
      expect(parser.call.dig(:candidates, :total_amount)).to eq(summary_amount.to_i)
    end
  end

  it 'rejects an oversized structured Total before decimal conversion' do
    item = positive_cases.first.fetch('item').deep_dup
    response = synthetic_response(item)
    parser = Ocr::ResponseParser.new(response:, provider: :fixture)
    total = {
      'valueCurrency' => { 'amount' => 10**10_000, 'currencyCode' => 'JPY' }
    }

    expect(parser).not_to receive(:BigDecimal)
    expect(parser.send(:strict_document_total_amount, total, '300')).to be_nil
  end

  it 'indexes bounded provider content once while validating a dense summary-line receipt' do
    item = positive_cases.first.fetch('item').deep_dup
    response = synthetic_response(item)
    summary_amount = item.dig('valueObject', 'TotalPrice', 'content')
    while response.dig('analyzeResult', 'pages', 0, 'lines').size < 149
      append_response_line(response, 'X' * 500)
    end
    append_response_line(response, "合計 #{summary_amount}円")
    parser = Ocr::ResponseParser.new(response:, provider: :fixture)

    Timeout.timeout(2) do
      expect(parser.send(:extract_strict_summary_total_from_response, response)).to eq(
        summary_amount.to_i
      )
    end
  end

  it 'does not widen separated tax-label binding on the existing Azure Items path' do
    content = "SYNTH-TAX-SCOPE\n税抜10% 181円/250ml\n1.5 L"
    price_content = '税抜10% 181円/250ml'
    quantity_content = '1.5 L'
    price_offset = content.index(price_content)
    quantity_offset = content.index(quantity_content)
    item = {
      'content' => content,
      'spans' => [ { 'offset' => 0, 'length' => content.length } ],
      'valueObject' => {
        'Price' => {
          'content' => price_content,
          'spans' => [ { 'offset' => price_offset, 'length' => price_content.length } ]
        },
        'Quantity' => {
          'content' => quantity_content,
          'spans' => [ { 'offset' => quantity_offset, 'length' => quantity_content.length } ]
        }
      }
    }

    candidate = extract([ item ]).sole

    expect(candidate).to include(
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price_tax_inclusion: 'unknown',
      tax_inclusion_evidence: nil
    )

    prefixed = item.deep_dup
    prefixed_content = "SYNTH-TAX-PREFIX\n非税込 181円/250ml\n1.5 L"
    prefixed_price = '非税込 181円/250ml'
    prefixed['content'] = prefixed_content
    prefixed['spans'] = [ { 'offset' => 0, 'length' => utf16_length(prefixed_content) } ]
    prefixed.dig('valueObject', 'Price').merge!(
      'content' => prefixed_price,
      'spans' => [ { 'offset' => prefixed_content.index(prefixed_price), 'length' => utf16_length(prefixed_price) } ]
    )
    prefixed.dig('valueObject', 'Quantity')['spans'] = [
      { 'offset' => prefixed_content.index(quantity_content), 'length' => utf16_length(quantity_content) }
    ]

    expect(extract([ prefixed ]).sole).to include(
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price_tax_inclusion: 'unknown',
      tax_inclusion_evidence: nil
    )

    [ '非:税込', '非（税込', 'NOT 税込', 'ＮＯＴ：税込' ].each do |negated_label|
      negated = item.deep_dup
      negated_price = "#{negated_label} 181円/250ml"
      negated_content = "SYNTH-TAX-NEGATION\n#{negated_price}\n#{quantity_content}"
      negated['content'] = negated_content
      negated['spans'] = [ { 'offset' => 0, 'length' => utf16_length(negated_content) } ]
      negated.dig('valueObject', 'Price').merge!(
        'content' => negated_price,
        'spans' => [ { 'offset' => negated_content.index(negated_price), 'length' => utf16_length(negated_price) } ]
      )
      negated.dig('valueObject', 'Quantity')['spans'] = [
        { 'offset' => negated_content.index(quantity_content), 'length' => utf16_length(quantity_content) }
      ]

      expect(extract([ negated ]).sole).to include(
        validation_state: 'ambiguous',
        reference_price_tax_inclusion: 'unknown',
        tax_inclusion_evidence: nil
      )
    end
  end

  it 'does not bind a negated tax substring on the structured Price fallback' do
    item = structured_item(
      description: 'SYNTH-TAX-NEGATED',
      price: { content: '非税込 149円', amount: 149 },
      quantity: { content: '4 L', amount: 4 },
      unit: { content: 'L', value: 'L' },
      total: { content: '596円', amount: 596 }
    )

    expect(extract([ item ]).sole).to include(
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price_tax_inclusion: 'unknown',
      tax_inclusion_evidence: nil
    )
  end

  it 'binds all emitted evidence to the same Azure item and its exact structured field path' do
    positive_cases.each do |case_data|
      item = case_data.fetch('item')
      candidate = extract([ item ]).sole
      parent = item.fetch('spans').sole
      parent_end = parent.fetch('offset') + parent.fetch('length')

      AZURE_MEASUREMENT_SOURCE_FIELDS.each do |component, field_name|
        evidence = candidate.dig(component, :evidence)
        expected_text = case component
        when :reference_price then case_data.dig('expected', 'reference_price_amount')
        when :reference_quantity then item.dig('valueObject', 'QuantityUnit', 'valueString')
        when :purchased_quantity then case_data.dig('expected', 'purchased_quantity')
        when :printed_line_total then case_data.dig('expected', 'printed_total')
        end

        aggregate_failures "#{case_data.fetch('case_id')} #{component}" do
          expect(evidence).to include(
            source_provider: 'azure_structured',
            source_field_path: "documents[0].fields.Items[0].#{field_name}",
            item_index: 0
          )
          expect(evidence.fetch(:provider_span_start)).to be >= parent.fetch('offset')
          expect(evidence.fetch(:provider_span_end)).to be <= parent_end
          expect(evidence.fetch(:provider_span_end)).to be >= evidence.fetch(:provider_span_start)
          expect(utf16_slice(
            item.fetch('content'),
            evidence.fetch(:provider_span_start),
            evidence.fetch(:provider_span_end)
          )).to eq(expected_text)
        end
      end
    end
  end

  it 'prefers the structured Price over a nearby discount expression and does not expose raw text' do
    case_data = positive_cases.find { |entry| entry.fetch('case_id') == 'volume_discount_nearby' }
    item = case_data.fetch('item')
    candidate = extract([ item ]).sole

    aggregate_failures do
      expect(candidate.dig(:reference_price, :amount)).to eq('137')
      expect(candidate.to_json).not_to include('discount')
      expect(candidate.to_json).not_to include(item.dig('valueObject', 'Description', 'valueString'))
    end
  end

  it 'preserves a legitimate explicit basis that follows a separate discount line' do
    content = "SYNTH-LEGIT\n値引 -6\n税込 142円/1L\n3 L\n420"
    item = {
      'content' => content,
      'spans' => [ { 'offset' => 0, 'length' => 36 } ],
      'valueObject' => {
        'Description' => {
          'content' => 'SYNTH-LEGIT',
          'spans' => [ { 'offset' => 0, 'length' => 11 } ],
          'valueString' => 'SYNTH-LEGIT'
        },
        'Quantity' => {
          'content' => '3 L',
          'spans' => [ { 'offset' => 29, 'length' => 3 } ],
          'valueNumber' => 3
        },
        'QuantityUnit' => {
          'content' => 'L',
          'spans' => [ { 'offset' => 31, 'length' => 1 } ],
          'valueString' => 'L'
        },
        'TotalPrice' => {
          'content' => '420',
          'spans' => [ { 'offset' => 33, 'length' => 3 } ],
          'valueCurrency' => { 'amount' => 420, 'currencyCode' => 'JPY' }
        }
      }
    }

    candidate = extract([ item ]).sole

    aggregate_failures do
      expect(candidate.dig(:reference_price, :amount)).to eq('142')
      expect(candidate.dig(:reference_quantity, :unit_code)).to eq('liter')
      expect(candidate.dig(:printed_line_total, :amount)).to eq('420')
    end
  end

  it 'preserves an explicit post-discount basis in the structured Price field' do
    item = structured_item(
      description: 'SYNTH-POST-DISCOUNT',
      price: { content: '値引後 149円/1L', amount: 149 },
      quantity: { content: '4 L', amount: 4 },
      unit: { content: 'L', value: 'L' },
      total: { content: '596', amount: 596 }
    )

    candidate = extract([ item ]).sole

    aggregate_failures do
      expect(candidate.dig(:reference_price, :amount)).to eq('149')
      expect(candidate.dig(:reference_quantity, :unit_code)).to eq('liter')
      expect(candidate.dig(:printed_line_total, :amount)).to eq('596')
    end
  end

  it 'does not fall back to a discount expression when the structured Price is unavailable' do
    case_data = positive_cases.find { |entry| entry.fetch('case_id') == 'volume_discount_nearby' }
    item = case_data.fetch('item').deep_dup
    item.fetch('valueObject').delete('Price')

    expect(extract([ item ])).to eq([])
  end

  it 'does not treat arithmetic agreement as authority for a discount expression' do
    case_data = positive_cases.find { |entry| entry.fetch('case_id') == 'volume_discount_nearby' }
    item = case_data.fetch('item').deep_dup
    item.fetch('valueObject').delete('Price')
    item['content'] = item.fetch('content').sub(/548\z/, '016')
    item.dig('valueObject', 'TotalPrice').merge!(
      'content' => '016',
      'valueCurrency' => { 'amount' => 16, 'currencyCode' => 'JPY' }
    )

    expect(extract([ item ])).to eq([])
  end

  it 'fails closed when a structured Price conflicts with an explicit post-discount basis' do
    item = positive_cases.first.fetch('item').deep_dup
    conflicting_basis = "\n値引後 131円/1L"
    item['content'] += conflicting_basis
    item.fetch('spans').sole['length'] += conflicting_basis.encode(Encoding::UTF_16LE).bytesize / 2

    expect(extract([ item ])).to eq([])
  end

  it 'keeps the structured Price when a generic same-line discount amount is also present' do
    item = positive_cases.first.fetch('item').deep_dup
    adjustment = "\ndiscount 7円/L"
    item['content'] += adjustment
    item.fetch('spans').sole['length'] += adjustment.encode(Encoding::UTF_16LE).bytesize / 2

    candidate = extract([ item ]).sole

    aggregate_failures do
      expect(candidate.dig(:reference_price, :amount)).to eq(
        positive_cases.first.dig('expected', 'reference_price_amount')
      )
      expect(candidate.dig(:reference_price, :evidence, :source_field_path)).to end_with('.Price')
    end
  end

  it 'does not let malformed structured placeholders suppress the legacy root candidate' do
    content = "SYNTH-ROOT\n値引 -6\n143円/1L 3 L"
    item = {
      'content' => content,
      'spans' => [ { 'offset' => 0, 'length' => content.length } ],
      'valueObject' => {
        'Quantity' => {},
        'QuantityUnit' => {},
        'TotalPrice' => {}
      }
    }

    candidate = extract([ item ]).sole

    aggregate_failures do
      expect(candidate.dig(:reference_price, :amount)).to eq('143')
      expect(candidate.dig(:reference_quantity, :unit_code)).to eq('liter')
    end
  end

  it 'keeps all count unit-price and package-content shapes outside reference pricing' do
    results = negative_cases.to_h do |case_data|
      [ case_data.fetch('case_id'), extract([ case_data.fetch('item') ]) ]
    end

    aggregate_failures do
      expect(results.values).to all(eq([]))
      expect(results.keys.grep(/\Acount_/).size).to eq(6)
      expect(results.keys.grep(/\Apackage_/).size).to eq(4)
    end
  end

  it 'rejects package capacity duplicated by separate structured quantity fields' do
    package = negative_cases.find { |entry| entry.fetch('case_id') == 'package_capacity' }
      .fetch('item')
    overlapping = package.deep_dup.tap do |item|
      item.dig('valueObject', 'Quantity').merge!(
        'content' => '650',
        'spans' => [ { 'offset' => 16, 'length' => 3 } ]
      )
      item.dig('valueObject', 'QuantityUnit').merge!(
        'content' => 'ml',
        'spans' => [ { 'offset' => 19, 'length' => 2 } ]
      )
    end

    aggregate_failures do
      expect(extract([ package ])).to eq([])
      expect(extract([ overlapping ])).to eq([])
    end
  end

  it 'rejects an exactly convertible package capacity written in another unit' do
    package = negative_cases.find { |entry| entry.fetch('case_id') == 'package_capacity' }
      .fetch('item').deep_dup
    package['content'] = package.fetch('content').sub('650ml入り', '0.65L入り')
    package.dig('valueObject', 'Description').merge!(
      'content' => package.dig('valueObject', 'Description', 'content').sub('650ml入り', '0.65L入り'),
      'valueString' => package.dig('valueObject', 'Description', 'valueString').sub('650ml入り', '0.65L入り')
    )

    expect(extract([ package ])).to eq([])
  end

  it 'rejects a convertible package capacity followed by an unlisted Japanese suffix' do
    package = negative_cases.find { |entry| entry.fetch('case_id') == 'package_capacity' }
      .fetch('item').deep_dup
    package['content'] = package.fetch('content').sub('650ml入り', '0.65L容量')
    package.dig('valueObject', 'Description').merge!(
      'content' => package.dig('valueObject', 'Description', 'content').sub('650ml入り', '0.65L容量'),
      'valueString' => package.dig('valueObject', 'Description', 'valueString').sub('650ml入り', '0.65L容量')
    )

    expect(extract([ package ])).to eq([])
  end

  it 'does not interpret the prefix of an ordinary word as a quantity unit' do
    item = structured_item(
      description: 'SYNTH 2 lemons',
      price: { content: '100', amount: 100 },
      quantity: { content: '2 L', amount: 2 },
      unit: { content: 'L', value: 'L' },
      total: { content: '200', amount: 200 }
    )

    candidate = extract([ item ]).sole

    aggregate_failures do
      expect(candidate.dig(:reference_price, :amount)).to eq('100')
      expect(candidate.dig(:purchased_quantity, :unit_code)).to eq('liter')
    end
  end

  it 'rejects a discount-labelled structured Price even when its formula agrees' do
    item = structured_item(
      description: 'SYNTH-DISCOUNT-FIELD',
      price: { content: 'discount 3円/L', amount: 3 },
      quantity: { content: '3 L', amount: 3 },
      unit: { content: 'L', value: 'L' },
      total: { content: '9', amount: 9 }
    )

    expect(extract([ item ])).to eq([])
  end

  it 'fails closed for formula mismatch, non-JPY structured currency, unit conflict, and outside-item spans' do
    baseline = positive_cases.first.fetch('item')
    malformed = [
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'TotalPrice')['content'] = '999'
        item.dig('valueObject', 'TotalPrice', 'valueCurrency')['amount'] = 999
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Price', 'valueCurrency')['currencyCode'] = 'USD'
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'QuantityUnit')['valueString'] = 'kg'
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Quantity', 'spans', 0)['offset'] = item.fetch('spans').sole.fetch('length') + 1
      end
    ]

    expect(malformed.map { |item| extract([ item ]) }).to all(eq([]))
  end

  it 'fails closed when structured field text, spans, or currency provenance are incomplete' do
    baseline = positive_cases.first.fetch('item')
    malformed = [
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Quantity', 'spans', 0)['length'] += 1
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Price')['content'] = '@124'
        item.dig('valueObject', 'Price', 'valueCurrency')['amount'] = 124
        item.dig('valueObject', 'TotalPrice')['content'] = '310'
        item.dig('valueObject', 'TotalPrice', 'valueCurrency')['amount'] = 310
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Price', 'valueCurrency').delete('currencyCode')
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'TotalPrice', 'valueCurrency').delete('currencyCode')
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Description', 'spans', 0)['length'] = 0
      end,
      baseline.deep_dup.tap do |item|
        item.dig('valueObject', 'Price', 'spans') << nil
      end,
      baseline.deep_dup.tap do |item|
        item.fetch('valueObject').delete('Description')
      end
    ]

    expect(malformed.map { |item| extract([ item ]) }).to all(eq([]))
  end

  it 'does not borrow a quantity span from an adjacent item' do
    first = positive_cases.first.fetch('item').deep_dup
    second = positive_cases.second.fetch('item').deep_dup
    second_length = second.fetch('spans').sole.fetch('length')
    second.fetch('spans').sole.merge!('offset' => 1_000, 'length' => second_length)
    second.fetch('valueObject').each_value do |field|
      field.fetch('spans').each { |span| span['offset'] += 1_000 }
    end
    first.dig('valueObject', 'Quantity', 'spans', 0)['offset'] = 1_000

    candidates = extract([ first, second ])

    aggregate_failures do
      expect(candidates.none? { |candidate| candidate[:item_index] == 0 }).to be(true)
      expect(candidates.map { |candidate| candidate[:item_index] }).to eq([ 1 ])
    end
  end

  it 'keeps the top-level parser and build-params pipeline candidate-only' do
    item = positive_cases.first.fetch('item')
    ocr_result = Ocr::ResponseParser.new(response: synthetic_response(item), provider: :fixture).call
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)
    receipt_item = params.fetch(:receipt_items_attributes).sole

    aggregate_failures do
      expect(ocr_result.dig(:candidates, :reference_pricing_candidates).size).to eq(1)
      expect(params.fetch(:reference_pricing_candidates).size).to eq(1)
      expect(receipt_item.keys).not_to include(
        :pricing_source_kind,
        :reference_price_amount,
        :reference_quantity,
        :reference_quantity_unit_code,
        :reference_price_tax_inclusion
      )
    end
  end

  it 'stores only the bounded candidate allowlist in the OCR snapshot' do
    item = positive_cases.first.fetch('item')
    candidate = extract([ item ]).sole.merge(
      raw_text: 'PRIVATE RAW RECEIPT TEXT',
      provider_raw_response: 'PRIVATE PROVIDER PAYLOAD'
    )
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(
      success: true,
      candidates: { reference_pricing_candidates: [ candidate ] }
    )
    stored = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(stored).to include(
        'validation_state' => 'ambiguous',
        'rejection_reasons' => [ 'ambiguous_tax_inclusion' ],
        'reference_price_tax_inclusion' => 'unknown'
      )
      expect(stored.dig('reference_quantity', 'origin')).to eq('implicit_per_unit')
      expect(stored.to_json).not_to include(
        'PRIVATE RAW RECEIPT TEXT',
        'PRIVATE PROVIDER PAYLOAD',
        'raw_text',
        'provider_raw_response'
      )
    end
  end
end
