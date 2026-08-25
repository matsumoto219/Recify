require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ItemCalculationModeCandidateExtractor do
  subject(:extract) do
    described_class.call(
      analyze_result: analyze_result_for(items),
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      reference_pricing_candidates: reference_pricing_candidates
    )
  end

  let(:reference_pricing_candidates) { [] }

  def fixture_items(name)
    fixture_analyze_result(name).dig('documents', 0, 'fields', 'Items', 'valueArray')
  end

  def fixture_analyze_result(name)
    response = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)

    response.fetch('analyzeResult')
  end

  def exact_item(
    price: 100,
    quantity: 2,
    unit: '個',
    total: 200,
    currency: 'JPY',
    price_content: nil,
    total_content: nil,
    quantity_content: nil,
    price_symbol: nil,
    total_symbol: nil,
    content: nil,
    offset: 100,
    description: '検証商品',
    string_index_type: 'utf16CodeUnit'
  )
    total_content ||= total.to_s
    quantity_content ||= quantity.to_s
    price_content ||= price.to_s
    content ||= [ description, total_content, "#{quantity_content}#{unit}", price_content ].join("\n")
    total_offset = offset + provider_length(description, string_index_type) + 1
    quantity_offset = total_offset + provider_length(total_content, string_index_type) + 1
    unit_offset = quantity_offset + provider_length(quantity_content, string_index_type)
    price_offset = unit_offset + provider_length(unit, string_index_type) + 1

    {
      'content' => content,
      'spans' => [ { 'offset' => offset, 'length' => provider_length(content, string_index_type) } ],
      'valueObject' => {
        'Description' => {
          'valueString' => description,
          'content' => description,
          'spans' => [ { 'offset' => offset, 'length' => provider_length(description, string_index_type) } ]
        },
        'TotalPrice' => currency_field(total, total_content, total_offset, currency:, symbol: total_symbol),
        'Quantity' => {
          'valueNumber' => quantity,
          'content' => quantity_content,
          'spans' => [ { 'offset' => quantity_offset, 'length' => provider_length(quantity_content, string_index_type) } ]
        },
        'QuantityUnit' => {
          'valueString' => unit,
          'content' => unit,
          'spans' => [ { 'offset' => unit_offset, 'length' => provider_length(unit, string_index_type) } ]
        },
        'Price' => currency_field(price, price_content, price_offset, currency:, symbol: price_symbol)
      }
    }
  end

  def provider_length(value, index_type)
    Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: index_type).length(value)
  end

  def analyze_result_for(
    items,
    model_id: described_class::SUPPORTED_MODEL_ID,
    api_version: described_class::SUPPORTED_API_VERSION,
    string_index_type: 'utf16CodeUnit',
    content: nil
  )
    content ||= items.sort_by { |item| item.dig('spans', 0, 'offset').to_i }.each_with_object(+'') do |item, value|
      offset = item.dig('spans', 0, 'offset')
      next unless offset.is_a?(Integer) && offset >= value.length

      value << (' ' * (offset - value.length))
      value << item['content'].to_s
    end

    {
      'modelId' => model_id,
      'apiVersion' => api_version,
      'stringIndexType' => string_index_type,
      'content' => content,
      'documents' => [
        { 'fields' => { 'Items' => { 'valueArray' => items } } }
      ]
    }
  end

  def append_item_content!(item, suffix)
    item['content'] = "#{item.fetch('content')}\n#{suffix}"
    item.fetch('spans').sole['length'] = item.fetch('content').length
  end

  def currency_field(amount, content, offset, currency: 'JPY', symbol: nil)
    {
      'valueCurrency' => {
        'amount' => amount,
        'currencyCode' => currency,
        'currencySymbol' => symbol
      }.compact,
      'content' => content,
      'spans' => [ { 'offset' => offset, 'length' => content.length } ]
    }
  end

  def modes(candidate)
    candidate.fetch(:options).map { |option| option.fetch(:pricing_source_kind) }
  end

  describe '.call' do
    context 'with exact Azure structured item evidence' do
      let(:items) { fixture_items('single_tax_receipt') }

      subject(:extract) do
        described_class.call(
          analyze_result: fixture_analyze_result('single_tax_receipt'),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: reference_pricing_candidates
        )
      end

      it 'creates count and explicit options from the same item parent without raw product text' do
        expect(extract.size).to eq(4)
        expect(extract).to all(include(source_provider: 'azure_structured'))
        expect(extract.map { |candidate| modes(candidate) }).to all(
          eq(%w[count_unit_price explicit_line_total])
        )

        first = extract.first
        aggregate_failures do
          expect(first[:candidate_id]).to eq('azure_items_0_item_calculation_mode')
          expect(first[:item_identity]).to eq('azure_structured_item_i0_s99_e118')
          expect(first[:item_index]).to eq(0)
          expect(first[:source_field_path]).to eq('documents[0].fields.Items[0]')
          expect(first[:printed_line_total]).to include(amount: '220')
          expect(first.dig(:options, 0, :source)).to eq(
            price_amount: '220',
            quantity: '1',
            quantity_unit_code: 'item'
          )
          expect(first.dig(:options, 1, :source)).to eq(line_total_amount: '220')
          expect(first.to_s).not_to include('ノート A5')
        end
      end

      it 'preserves exact component paths and provider spans' do
        count = extract.first.fetch(:options).first

        expect(count[:evidence]).to eq(
          price: {
            source_field_path: 'documents[0].fields.Items[0].Price',
            provider_span_start: 114,
            provider_span_end: 118
          },
          quantity: {
            source_field_path: 'documents[0].fields.Items[0].Quantity',
            provider_span_start: 111,
            provider_span_end: 112
          },
          quantity_unit: {
            source_field_path: 'documents[0].fields.Items[0].QuantityUnit',
            provider_span_start: 112,
            provider_span_end: 113
          }
        )
      end
    end

    context 'with existing anonymous fixtures' do
      it 'finds only the two exact multi-count items in the long receipt' do
        candidates = described_class.call(
          analyze_result: fixture_analyze_result('long_receipt'),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )

        expect(candidates.count { |candidate| modes(candidate).include?('count_unit_price') }).to eq(2)
        expect(candidates.filter_map do |candidate|
          candidate[:item_index] if modes(candidate).include?('count_unit_price')
        end).to eq([ 8, 12 ])
      end

      it 'does not reinterpret product-name capacity as purchased quantity' do
        candidates = described_class.call(
          analyze_result: fixture_analyze_result('unusual_units_receipt'),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )

        expect(candidates).to all(satisfy do |candidate|
          modes(candidate) == [ 'explicit_line_total' ]
        end)
      end

      it 'keeps a one-span item TotalPrice with the profile-owned tax marker' do
        candidates = described_class.call(
          analyze_result: fixture_analyze_result('tax_detail_item_conflict_receipt'),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )

        expect(candidates.find { |candidate| candidate[:item_index] == 0 }).to include(
          options: [ include(
            pricing_source_kind: 'explicit_line_total',
            source: { line_total_amount: '120' }
          ) ]
        )
      end
    end

    context 'when formula evidence is incomplete or unsafe' do
      let(:items) { [ exact_item ] }

      it 'does not use a missing Quantity as an implicit quantity of one' do
        items.first['valueObject'].delete('Quantity')

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'does not use an unknown unit as count authority' do
        items.first['valueObject']['QuantityUnit'].merge!(
          'valueString' => '杯',
          'content' => '杯'
        )

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects contradictory printed currency evidence for Price and TotalPrice independently' do
        foreign_price = exact_item(price_content: '$100', price_symbol: '$')
        foreign_total = exact_item(total_content: '$200', total_symbol: '$')

        price_result = described_class.call(
          analyze_result: analyze_result_for([ foreign_price ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )
        total_result = described_class.call(
          analyze_result: analyze_result_for([ foreign_total ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )

        aggregate_failures do
          expect(modes(price_result.sole)).to eq([ 'explicit_line_total' ])
          expect(modes(total_result.sole)).to eq([ 'count_unit_price' ])
        end
      end

      it 'accepts absent and canonical JPY currency markers' do
        [ [ '¥100', '¥' ], [ '￥100', '￥' ], [ '100円', '円' ], [ 'JPY 100', nil ] ].each do |content, symbol|
          item = exact_item(price_content: content, price_symbol: symbol)

          result = described_class.call(
            analyze_result: analyze_result_for([ item ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )

          expect(modes(result.sole)).to include('count_unit_price')
        end
      end

      it 'rejects signed or accounting-style Price, TotalPrice, and Quantity lexemes independently' do
        [ '-100', '−100', '▲100', '(100)', '+100' ].each do |signed_price|
          result = described_class.call(
            analyze_result: analyze_result_for([ exact_item(price_content: signed_price) ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
        end

        [ '-200', '−200', '▲200', '(200)', '+200' ].each do |signed_total|
          result = described_class.call(
            analyze_result: analyze_result_for([ exact_item(total_content: signed_total) ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
          expect(modes(result.sole)).to eq([ 'count_unit_price' ])
        end

        [ '-2', '−2', '▲2', '(2)', '+2' ].each do |signed_quantity|
          result = described_class.call(
            analyze_result: analyze_result_for([ exact_item(quantity_content: signed_quantity) ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
        end
      end

      it 'rejects malformed raw provider numeric types before typed proposal construction' do
        [ '100', BigDecimal('100'), true, {}, [] ].each do |malformed|
          malformed_price = exact_item
          malformed_price.dig('valueObject', 'Price', 'valueCurrency')['amount'] = malformed
          malformed_total = exact_item
          malformed_total.dig('valueObject', 'TotalPrice', 'valueCurrency')['amount'] = malformed
          malformed_quantity = exact_item
          malformed_quantity.dig('valueObject', 'Quantity')['valueNumber'] = malformed

          price_result = described_class.call(
            analyze_result: analyze_result_for([ malformed_price ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
          total_result = described_class.call(
            analyze_result: analyze_result_for([ malformed_total ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
          quantity_result = described_class.call(
            analyze_result: analyze_result_for([ malformed_quantity ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )

          aggregate_failures do
            expect(modes(price_result.sole)).to eq([ 'explicit_line_total' ])
            expect(modes(total_result.sole)).to eq([ 'count_unit_price' ])
            expect(modes(quantity_result.sole)).to eq([ 'explicit_line_total' ])
          end
        end
      end

      it 'does not reinterpret a reference price expression as a count unit price' do
        reference_pricing_candidates << { item_index: 0 }

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'keeps a destination carrier for a valid structured reference without TotalPrice' do
        items.first.fetch('valueObject').delete('TotalPrice')
        reference_pricing_candidates << {
          item_index: 0,
          validation_state: 'valid',
          rejection_reasons: []
        }

        aggregate_failures do
          expect(extract.sole[:item_identity]).to eq('azure_structured_item_i0_s100_e115')
          expect(extract.sole[:options]).to be_empty
          expect(extract.sole[:conflicts]).to eq([ 'reference_expression' ])
        end
      end

      it 'does not create an empty carrier for an ambiguous structured reference' do
        items.first.fetch('valueObject').delete('TotalPrice')
        reference_pricing_candidates << {
          item_index: 0,
          validation_state: 'ambiguous',
          rejection_reasons: [ 'tax_basis_unknown' ]
        }

        expect(extract).to be_empty
      end

      it 'does not adopt a package-content quantity as purchased quantity' do
        append_item_content!(items.first, '10個入')

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects mass-capacity and nested package expressions' do
        %w[500ml入り].each do |suffix|
          packaged_item = exact_item
          append_item_content!(packaged_item, suffix)
          result = described_class.call(
            analyze_result: analyze_result_for([ packaged_item ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )

          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
        end

        packaged_item = exact_item
        append_item_content!(packaged_item, '2袋 x 100g')
        result = described_class.call(
          analyze_result: analyze_result_for([ packaged_item ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects approximate and ranged count semantics' do
        [ '約2個', '2〜3個', '2個前後' ].each do |uncertain_quantity|
          uncertain_item = exact_item
          append_item_content!(uncertain_item, uncertain_quantity)

          result = described_class.call(
            analyze_result: analyze_result_for([ uncertain_item ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )

          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
          expect(result.sole[:conflicts]).to include('count_semantics')
        end
      end

      it 'rejects multi-buy and promotion semantics' do
        [ '2個で300円', 'まとめ買い' ].each do |multi_buy|
          promoted_item = exact_item
          append_item_content!(promoted_item, multi_buy)

          result = described_class.call(
            analyze_result: analyze_result_for([ promoted_item ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )

          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
          expect(result.sole[:conflicts]).to include('count_semantics')
        end
      end

      it 'normalizes full-width conflict notation without changing provider spans' do
        [ '２袋Ｘ１００ｇ', '２個－３個', 'ＤＩＳＣＯＵＮＴ' ].each do |full_width_conflict|
          conflicted_item = exact_item
          append_item_content!(conflicted_item, full_width_conflict)

          result = described_class.call(
            analyze_result: analyze_result_for([ conflicted_item ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )

          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
        end
      end

      it 'uses the injected profile package pattern instead of shared hardcoded vocabulary' do
        injected_profile = Class.new do
          define_method(:resolve_quantity_unit) do |value|
            ReceiptAnalysisProfiles.fetch('JPN').resolve_quantity_unit(value)
          end

          define_method(:ocr_item_discount_keyword_pattern) { /NEVER_DISCOUNT/ }
          define_method(:ocr_item_calculation_package_quantity_pattern) { /BUNDLE_MARKER/ }
          define_method(:ocr_item_calculation_package_capacity_pattern) { /NEVER_CAPACITY/ }
          define_method(:ocr_item_calculation_count_uncertain_pattern) { /NEVER_COUNT_UNCERTAIN/ }
          define_method(:ocr_item_calculation_tax_marker_prefix_pattern) { /\A(?!)/ }
        end.new
        append_item_content!(items.first, 'BUNDLE_MARKER')

        result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: injected_profile,
          reference_pricing_candidates: []
        )

        expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'does not create count authority from a discounted item block' do
        append_item_content!(items.first, '値引')

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'uses the existing adjacent-discount association as a count conflict' do
        result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: [],
          discount_item_indexes: [ 0 ]
        )

        expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'does not reuse description/package spans as purchased quantity evidence' do
        item = exact_item(description: '詰合せ商品 5箱')
        description = item.dig('valueObject', 'Description')
        quantity_offset = description.dig('spans', 0, 'offset') + description.fetch('content').index('5')
        item.dig('valueObject', 'Quantity').merge!(
          'valueNumber' => 5,
          'content' => '5',
          'spans' => [ { 'offset' => quantity_offset, 'length' => 1 } ]
        )
        item.dig('valueObject', 'QuantityUnit').merge!(
          'valueString' => '箱',
          'content' => '箱',
          'spans' => [ { 'offset' => quantity_offset + 1, 'length' => 1 } ]
        )

        result = described_class.call(
          analyze_result: analyze_result_for([ item ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )

        expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'keeps both exact options when their amounts disagree for the decision layer to resolve' do
        items.replace([ exact_item(total: 201) ])

        expect(modes(extract.sole)).to eq(%w[count_unit_price explicit_line_total])
        expect(extract.sole.dig(:printed_line_total, :amount)).to eq('201')
      end
    end

    context 'at numeric and evidence boundaries' do
      let(:items) { [ exact_item ] }

      it 'keeps an explicitly printed zero total distinct from a missing total' do
        items.replace([ exact_item(total: 0) ])

        explicit = extract.sole.fetch(:options).find do |option|
          option[:pricing_source_kind] == 'explicit_line_total'
        end

        expect(explicit[:source]).to eq(line_total_amount: '0')
      end

      it 'rejects fractional quantities for countable units' do
        quantity = items.first.dig('valueObject', 'Quantity')
        quantity.merge!('valueNumber' => 1.5, 'content' => '1.5')

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects fractional JPY at the Price and TotalPrice integer boundary independently' do
        fractional_price = described_class.call(
          analyze_result: analyze_result_for([ exact_item(price: 100.5) ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )
        fractional_total = described_class.call(
          analyze_result: analyze_result_for([ exact_item(total: 200.5) ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )

        aggregate_failures do
          expect(modes(fractional_price.sole)).to eq([ 'explicit_line_total' ])
          expect(modes(fractional_total.sole)).to eq([ 'count_unit_price' ])
        end
      end

      it 'accepts the maximum persisted quantity and rejects the first value above it' do
        items.replace([ exact_item(quantity: 9999) ])
        maximum_result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(modes(maximum_result.sole)).to include('count_unit_price')

        items.replace([ exact_item(quantity: 10_000) ])
        above_maximum_result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(modes(above_maximum_result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects a non-JPY money component' do
        items.first['valueObject']['Price'] = currency_field(100, '100', 114, currency: 'USD')
        items.first['valueObject']['TotalPrice'] = currency_field(200, '200', 105, currency: 'USD')

        expect(extract).to eq([])
      end

      it 'rejects child evidence outside its item parent' do
        items.first.dig('valueObject', 'Price', 'spans', 0)['offset'] = 10_000

        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'fails closed when item parent spans overlap' do
        items << exact_item(offset: 110)

        expect(extract).to eq([])
      end

      it 'rejects every item overlapped by a containing parent span' do
        extractor = described_class.new(
          analyze_result: {},
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: [],
          discount_item_indexes: []
        )

        expect(extractor.send(
          :overlapping_parent_indexes,
          [ 100...200, 110...134, 150...174 ]
        )).to eq(Set[0, 1, 2])
      end

      it 'accepts the maximum amount and rejects the first value above it' do
        maximum = described_class::MAX_AMOUNT.to_i
        items.replace([ exact_item(price: maximum, total: maximum) ])
        expect(modes(extract.sole)).to eq(%w[count_unit_price explicit_line_total])

        above_maximum = maximum + 1
        items.replace([ exact_item(price: above_maximum, total: above_maximum) ])

        above_maximum_result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(above_maximum_result).to eq([])
      end

      it 'rejects zero or negative purchased quantities' do
        items.replace([ exact_item(quantity: 0) ])
        zero_result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(modes(zero_result.sole)).to eq([ 'explicit_line_total' ])

        items.replace([ exact_item(quantity: -1) ])
        negative_result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(modes(negative_result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects multiple or overflowing component spans without raising' do
        price = items.first.dig('valueObject', 'Price')
        price['spans'] << price.fetch('spans').sole.deep_dup
        expect(modes(extract.sole)).to eq([ 'explicit_line_total' ])

        price['spans'] = [ { 'offset' => described_class::MAX_PROVIDER_SPAN_VALUE, 'length' => 1 } ]
        overflow_result = described_class.call(
          analyze_result: analyze_result_for(items),
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          reference_pricing_candidates: []
        )
        expect(modes(overflow_result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'rejects string and floating-point provider span types' do
        %w[offset length].each do |key|
          malformed = exact_item
          malformed.dig('valueObject', 'Price', 'spans', 0)[key] = '1'
          result = described_class.call(
            analyze_result: analyze_result_for([ malformed ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )
          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])

          malformed = exact_item
          malformed.dig('valueObject', 'Price', 'spans', 0)[key] = 1.0
          result = described_class.call(
            analyze_result: analyze_result_for([ malformed ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )
          expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
        end
      end

      it 'fails closed at the 99, 100, and 101 item source boundary' do
        results = [ 99, 100, 101 ].map do |count|
          bounded_items = count.times.map { |index| exact_item(offset: index * 32) }
          described_class.call(
            analyze_result: analyze_result_for(bounded_items),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )
        end

        expect(results.map(&:size)).to eq([ 99, 100, 0 ])
      end

      it 'accepts 4095 and 4096 byte item content and rejects 4097 bytes' do
        results = [ 4_095, 4_096, 4_097 ].map do |bytes|
          item = exact_item
          padding = bytes - item.fetch('content').bytesize - 1
          append_item_content!(item, 'a' * padding)
          described_class.call(
            analyze_result: analyze_result_for([ item ]),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )
        end

        expect(results.first(2).map(&:size)).to eq([ 1, 1 ])
        expect(results.last).to eq([])
      end

      it 'rejects invalid encoding, controls, and oversized structured strings without raising' do
        invalid_encoding = analyze_result_for(items)
        invalid_encoding['content'] = "\xFF".b
        controlled = exact_item
        append_item_content!(controlled, "unsafe\u202E")
        oversized_unit = exact_item
        oversized_unit.dig('valueObject', 'QuantityUnit')['valueString'] = 'a' * 513
        oversized_currency = exact_item
        oversized_currency.dig('valueObject', 'Price', 'valueCurrency')['currencyCode'] = 'J' * 9
        oversized_currency.dig('valueObject', 'TotalPrice', 'valueCurrency')['currencyCode'] = 'J' * 9

        expect do
          aggregate_failures do
            expect(described_class.call(
              analyze_result: invalid_encoding,
              profile: ReceiptAnalysisProfiles.fetch('JPN')
            )).to eq([])
            expect(described_class.call(
              analyze_result: analyze_result_for([ controlled ]),
              profile: ReceiptAnalysisProfiles.fetch('JPN')
            )).to eq([])
            expect(modes(described_class.call(
              analyze_result: analyze_result_for([ oversized_unit ]),
              profile: ReceiptAnalysisProfiles.fetch('JPN')
            ).sole)).to eq([ 'explicit_line_total' ])
            expect(described_class.call(
              analyze_result: analyze_result_for([ oversized_currency ]),
              profile: ReceiptAnalysisProfiles.fetch('JPN')
            )).to eq([])
          end
        end.not_to raise_error
      end

      it 'requires the supported Azure model, API version, and index type' do
        unsupported = [
          analyze_result_for(items, model_id: 'custom-receipt'),
          analyze_result_for(items, api_version: '2099-01-01'),
          analyze_result_for(items, string_index_type: 'utf8Byte')
        ]

        expect(unsupported.map do |analyze_result|
          described_class.call(
            analyze_result: analyze_result,
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
        end).to eq([ [], [], [] ])
      end

      it 'maps utf16CodeUnit and textElements spans exactly across emoji and combining text' do
        results = %w[utf16CodeUnit textElements].map do |index_type|
          item = exact_item(
            description: "Cafe\u0301😀",
            string_index_type: index_type
          )
          described_class.call(
            analyze_result: analyze_result_for(
              [ item ],
              string_index_type: index_type
            ),
            profile: ReceiptAnalysisProfiles.fetch('JPN')
          )
        end

        expect(results.map { |result| modes(result.sole) }).to all(
          eq(%w[count_unit_price explicit_line_total])
        )
      end

      it 'rejects a component whose span does not match the global provider content' do
        analyze_result = analyze_result_for(items)
        price = analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject', 'Price')
        price['content'] = '999'
        price.dig('valueCurrency')['amount'] = 999

        result = described_class.call(
          analyze_result: analyze_result,
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )

        expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'does not treat one provider token as both Price and TotalPrice authority' do
        item = exact_item(price: 200, total: 200)
        item.dig('valueObject')['TotalPrice'] = item.dig('valueObject', 'Price').deep_dup

        result = described_class.call(
          analyze_result: analyze_result_for([ item ]),
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )

        expect(modes(result.sole)).to eq([ 'explicit_line_total' ])
      end

      it 'ignores malformed and oversized collections without raising' do
        malformed = [ nil, 'item', {}, { 'spans' => [ { 'offset' => -1, 'length' => 2 } ] } ]

        expect do
          result = described_class.call(
            analyze_result: analyze_result_for(
              malformed + Array.new(150) { exact_item },
              content: ''
            ),
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            reference_pricing_candidates: []
          )
          expect(result.size).to be <= described_class::MAX_ITEMS
        end.not_to raise_error
      end
    end
  end
end
