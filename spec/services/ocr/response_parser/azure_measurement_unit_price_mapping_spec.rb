require 'rails_helper'

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
    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'apiVersion' => '2024-11-30',
        'modelId' => 'prebuilt-receipt',
        'content' => item.fetch('content'),
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
            'lines' => item.fetch('content').lines(chomp: true).map { |line| { 'content' => line } }
          }
        ]
      }
    }
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
