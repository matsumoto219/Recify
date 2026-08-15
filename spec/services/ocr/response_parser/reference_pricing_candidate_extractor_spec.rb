require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingCandidateExtractor do
  subject(:extract) do
    described_class.call(
      items: items,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
  end

  def fixture_items(name)
    response = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)

    response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray')
  end

  describe '.call' do
    context 'with the weighted-units fixture' do
      let(:items) { fixture_items('weighted_units_receipt') }

      it 'extracts exactly one bounded diagnostic candidate per printed reference-price item' do
        expect(extract.size).to eq(8)
        expect(extract.map { |candidate| candidate[:item_index] }).to eq((0..7).to_a)
        expect(extract).to all(include(
          validation_state: 'ambiguous',
          rejection_reasons: [ 'ambiguous_tax_inclusion' ],
          reference_price_tax_inclusion: 'unknown',
          tax_inclusion_evidence: nil
        ))
      end

      it 'keeps exact decimal source tokens and provider-global component evidence' do
        candidate = extract.first

        aggregate_failures do
          expect(candidate.keys).to contain_exactly(
            :candidate_id,
            :item_index,
            :validation_state,
            :rejection_reasons,
            :reference_price,
            :reference_quantity,
            :purchased_quantity,
            :reference_price_tax_inclusion,
            :tax_inclusion_evidence,
            :printed_line_total,
            :corroboration
          )
          expect(candidate[:candidate_id]).to eq('azure_items_0_reference_pricing')
          expect(candidate[:reference_price]).to eq(
            amount: '1480',
            evidence: {
              source_provider: 'azure_structured',
              source_field_path: 'documents[0].fields.Items[0].Price',
              item_index: 0,
              provider_span_start: 114,
              provider_span_end: 119
            }
          )
          expect(candidate[:reference_quantity]).to include(
            amount: '100', unit_code: 'gram', unit_status: 'known', origin: 'explicit'
          )
          expect(candidate[:purchased_quantity]).to include(
            amount: '342', unit_code: 'gram', unit_status: 'known'
          )
          expect(candidate.dig(:purchased_quantity, :evidence)).to include(
            source_field_path: 'documents[0].fields.Items[0].Quantity',
            item_index: 0,
            provider_span_start: 125,
            provider_span_end: 129
          )
          expect(candidate[:printed_line_total]).to include(amount: '5061')
          expect(candidate[:corroboration]).to eq(
            exact_amount: { numerator: '25308', denominator: '5' },
            projected_amount: 5062,
            printed_line_total: '5061',
            rounding_matches: [ 'floor' ]
          )
        end
      end

      it 'records an implicit reference quantity of one for a bare per-unit expression' do
        candidate = extract.fetch(1)

        expect(candidate[:reference_quantity]).to include(
          amount: '1',
          unit_code: 'kilogram',
          unit_status: 'known',
          origin: 'implicit_per_unit'
        )
      end


      it 'preserves every source lexeme and exact projection vector without binary Float conversion' do
        expected = [
          [ '1480', '100', 'gram', '342', 'gram', '25308', '5', 5062, '5061' ],
          [ '980', '1', 'kilogram', '1.25', 'kilogram', '1225', '1', 1225, '1225' ],
          [ '3280', '1', 'kilogram', '0.184', 'kilogram', '15088', '25', 604, '603' ],
          [ '1200', '1', 'liter', '0.75', 'liter', '900', '1', 900, '900' ],
          [ '120', '500', 'milliliter', '1500', 'milliliter', '360', '1', 360, '360' ],
          [ '980', '1000', 'cubic_centimeter', '250', 'cubic_centimeter', '245', '1', 245, '245' ],
          [ '1.8', '1', 'gram', '850', 'gram', '1530', '1', 1530, '1530' ],
          [ '0.9', '1', 'milligram', '1200', 'milligram', '1080', '1', 1080, '1080' ]
        ]

        actual = extract.map do |candidate|
          [
            candidate.dig(:reference_price, :amount),
            candidate.dig(:reference_quantity, :amount),
            candidate.dig(:reference_quantity, :unit_code),
            candidate.dig(:purchased_quantity, :amount),
            candidate.dig(:purchased_quantity, :unit_code),
            candidate.dig(:corroboration, :exact_amount, :numerator),
            candidate.dig(:corroboration, :exact_amount, :denominator),
            candidate.dig(:corroboration, :projected_amount),
            candidate.dig(:corroboration, :printed_line_total)
          ]
        end

        expect(actual).to eq(expected)
      end

      it 'selects the Description span containing the purchased quantity, not the product-name span' do
        candidate = extract.fetch(4)

        aggregate_failures do
          expect(candidate[:purchased_quantity]).to include(
            amount: '1500', unit_code: 'milliliter', unit_status: 'known'
          )
          expect(candidate.dig(:purchased_quantity, :evidence)).to include(
            source_field_path: 'documents[0].fields.Items[4].Description',
            provider_span_start: 264,
            provider_span_end: 270
          )
        end
      end
    end

    context 'with the unusual-units fixture' do
      let(:items) { fixture_items('unusual_units_receipt') }

      it 'extracts only the two explicit printed reference-price expressions' do
        expect(extract.size).to eq(2)
        expect(extract.map { |candidate| candidate[:item_index] }).to eq([ 7, 8 ])
      end
    end

    context 'with package-only quantity text' do
      let(:items) do
        [
          {
            'content' => "外8\n飲料 500ml入り\n¥198",
            'spans' => [ { 'offset' => 20, 'length' => 17 } ],
            'valueObject' => {
              'Description' => {
                'content' => '飲料 500ml入り',
                'spans' => [ { 'offset' => 23, 'length' => 10 } ]
              },
              'TotalPrice' => {
                'content' => '¥198',
                'valueCurrency' => { 'amount' => 198 },
                'spans' => [ { 'offset' => 33, 'length' => 4 } ]
              }
            }
          }
        ]
      end

      it 'does not invent a candidate without an explicit money-per-unit expression' do
        expect(extract).to eq([])
      end
    end

    context 'when a reference expression is followed only by product-name capacity' do
      let(:items) do
        [ '飲料 500ml', '500ml' ].map.with_index do |description, index|
          content = "税込 120円/100ml\n#{description}"
          offset = index * 100
          {
            'content' => content,
            'spans' => [ { 'offset' => offset, 'length' => content.length } ],
            'valueObject' => {
              'Price' => {
                'content' => '税込 120円/100ml',
                'spans' => [ { 'offset' => offset, 'length' => 14 } ]
              },
              'Description' => {
                'content' => description,
                'spans' => [ { 'offset' => offset + 15, 'length' => description.length } ]
              }
            }
          }
        end
      end

      it 'does not treat a capacity embedded in a product description as purchased quantity' do
        expect(extract).to all(include(
          validation_state: 'missing',
          rejection_reasons: include('missing_purchased_quantity', 'missing_purchased_unit'),
          purchased_quantity: nil
        ))
      end
    end

    context 'when package composition follows a reference expression' do
      let(:items) do
        [
          '税込 120円/1袋 2袋 x 100g',
          '税込 120円/1袋 2袋×100g',
          '税込 120円/1個 2個 @100円',
          '税込 10円/1g 120g gross',
          '税込 10円/1g 120g tare',
          '税込 10円/1g 120g 総重量',
          '税込 10円/1g 120g 風袋'
        ].map.with_index do |content, index|
          {
            'content' => content,
            'spans' => [ { 'offset' => index * 100, 'length' => content.length } ],
            'valueObject' => {}
          }
        end
      end

      it 'does not treat the package multiplier as purchased quantity' do
        expect(extract).to all(include(
          validation_state: 'missing',
          rejection_reasons: include('missing_purchased_quantity', 'missing_purchased_unit'),
          purchased_quantity: nil
        ))
      end
    end

    context 'with tax basis attached to the printed reference expression' do
      let(:items) do
        [
          {
            'content' => "商品\n税込 ¥498/100g\n342g\n¥1,703",
            'spans' => [ { 'offset' => 50, 'length' => 29 } ],
            'valueObject' => {
              'Price' => {
                'content' => '税込 ¥498/100g',
                'spans' => [ { 'offset' => 53, 'length' => 13 } ]
              },
              'Quantity' => {
                'content' => '342g',
                'valueNumber' => 342,
                'spans' => [ { 'offset' => 67, 'length' => 4 } ]
              },
              'QuantityUnit' => { 'valueString' => 'g' },
              'TotalPrice' => {
                'content' => '¥1,703',
                'spans' => [ { 'offset' => 72, 'length' => 6 } ]
              }
            }
          }
        ]
      end

      it 'emits a valid gross-basis candidate with same-item tax evidence' do
        candidate = extract.sole

        aggregate_failures do
          expect(candidate).to include(
            validation_state: 'valid',
            rejection_reasons: [],
            reference_price_tax_inclusion: 'gross'
          )
          expect(candidate[:tax_inclusion_evidence]).to include(
            source_field_path: 'documents[0].fields.Items[0].Price',
            item_index: 0,
            provider_span_start: 53,
            provider_span_end: 55
          )
        end
      end
    end

    context 'when structured provider values conflict with bounded field text' do
      let(:content) { '税込 ¥498/100g 342g ¥1,703' }
      let(:base_item) do
        {
          'content' => content,
          'spans' => [ { 'offset' => 0, 'length' => content.length } ],
          'valueObject' => {
            'Price' => {
              'content' => '税込 ¥498/100g',
              'valueCurrency' => { 'amount' => 498 },
              'spans' => [ { 'offset' => 0, 'length' => 12 } ]
            },
            'Quantity' => {
              'content' => '342g',
              'valueNumber' => 342,
              'spans' => [ { 'offset' => 13, 'length' => 4 } ]
            },
            'QuantityUnit' => { 'valueString' => 'g' },
            'TotalPrice' => {
              'content' => '¥1,703',
              'valueCurrency' => { 'amount' => 1_703 },
              'spans' => [ { 'offset' => 18, 'length' => 6 } ]
            }
          }
        }
      end

      it 'uses matching structured numbers only as corroboration' do
        candidate = described_class.call(
          items: [ base_item ],
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        ).sole

        expect(candidate).to include(validation_state: 'valid', rejection_reasons: [])
      end

      it 'marks price, purchased quantity, unit, and printed total conflicts ambiguous' do
        conflicting_items = [
          base_item.deep_dup.tap { |item| item.dig('valueObject', 'Price', 'valueCurrency')['amount'] = 999 },
          base_item.deep_dup.tap { |item| item.dig('valueObject', 'Quantity')['valueNumber'] = 999 },
          base_item.deep_dup.tap { |item| item.dig('valueObject', 'QuantityUnit')['valueString'] = 'kg' },
          base_item.deep_dup.tap { |item| item.dig('valueObject', 'TotalPrice', 'valueCurrency')['amount'] = 999 }
        ]

        conflicting_items.each do |item|
          candidate = described_class.call(
            items: [ item ],
            profile: ReceiptAnalysisProfiles.fetch('JPN'),
            projection: ReceiptAmountService.method(:reference_item_extension_projection)
          ).sole

          aggregate_failures do
            expect(candidate[:validation_state]).to eq('ambiguous')
            expect(candidate[:rejection_reasons]).to include('ambiguous_reference_expression')
            expect(candidate[:corroboration]).to be_nil
          end
        end
      end
    end


    context 'with a yen suffix reference expression' do
      let(:items) do
        [
          {
            'content' => "商品\n120円 / 500ml\n1500ml\n360円",
            'spans' => [ { 'offset' => 0, 'length' => 28 } ],
            'valueObject' => {}
          }
        ]
      end

      it 'extracts an explicit suffix-money token without accepting bare numerics' do
        expect(extract.sole[:reference_price]).to include(amount: '120')
      end
    end

    context 'with gross or ranged package measurements after the basis' do
      let(:items) do
        [
          {
            'content' => "商品\n¥498/100g\ngross 120g\n100-120g",
            'spans' => [ { 'offset' => 0, 'length' => 34 } ],
            'valueObject' => {}
          }
        ]
      end

      it 'does not adopt gross or range endpoints as purchased quantity' do
        expect(extract.sole).to include(
          validation_state: 'ambiguous',
          rejection_reasons: include('missing_purchased_quantity')
        )
      end
    end


    context 'with an unstructured purchased quantity on the next line' do
      let(:items) do
        content = "税込 120円 / 100g\n342g"
        [
          {
            'content' => content,
            'spans' => [ { 'offset' => 0, 'length' => content.length } ],
            'valueObject' => {}
          }
        ]
      end

      it 'does not associate an adjacent-line item-content token without component evidence' do
        expect(extract.sole).to include(
          validation_state: 'missing',
          rejection_reasons: include('missing_purchased_quantity', 'missing_purchased_unit'),
          purchased_quantity: nil
        )
      end
    end


    context 'when distinct Azure items claim the same parent provider span' do
      let(:items) do
        content = '税込 120円 / 100g 342g'
        item = {
          'content' => content,
          'spans' => [ { 'offset' => 500, 'length' => content.length } ],
          'valueObject' => {}
        }

        [ item, item.deep_dup ]
      end

      it 'preserves item identity and evidence while marking both candidates ambiguous' do
        candidates = extract

        aggregate_failures do
          expect(candidates.map { |candidate| candidate[:candidate_id] }).to eq(
            %w[azure_items_0_reference_pricing azure_items_1_reference_pricing]
          )
          expect(candidates).to all(include(
            validation_state: 'ambiguous',
            rejection_reasons: include('ambiguous_reference_expression')
          ))
          expect(candidates.map { |candidate| candidate.dig(:reference_price, :evidence, :provider_span_start) })
            .to eq([ 503, 503 ])
        end
      end
    end


    context 'when candidate evidence overlaps another Azure item parent span' do
      let(:items) do
        content = '税込 120円 / 100g 342g'
        [
          {
            'content' => content,
            'spans' => [ { 'offset' => 0, 'length' => content.length } ],
            'valueObject' => {}
          },
          {
            'content' => '342g',
            'spans' => [ { 'offset' => 15, 'length' => 4 } ],
            'valueObject' => {}
          }
        ]
      end

      it 'does not treat an adjacent-item overlap as valid purchased evidence' do
        expect(extract.sole).to include(
          item_index: 0,
          validation_state: 'ambiguous',
          rejection_reasons: include('ambiguous_reference_expression')
        )
      end
    end

    context 'when Azure item parent spans are distinct and non-overlapping' do
      let(:items) do
        content = '税込 120円 / 100g 342g'
        [ 0, 100 ].map do |offset|
          {
            'content' => content,
            'spans' => [ { 'offset' => offset, 'length' => content.length } ],
            'valueObject' => {}
          }
        end
      end

      it 'keeps both independently evidenced candidates valid' do
        expect(extract).to all(include(validation_state: 'valid', rejection_reasons: []))
      end
    end


    context 'with an over-magnitude provider span' do
      let(:items) do
        content = '税込 120円 / 100g 342g'
        [
          {
            'content' => content,
            'spans' => [ { 'offset' => 10**1_000, 'length' => content.length } ],
            'valueObject' => {}
          }
        ]
      end

      it 'fails closed without emitting unbounded evidence integers' do
        expect(extract).to eq([])
      end
    end

    context 'with an external unknown unit' do
      let(:items) do
        [
          {
            'content' => "商品\n税込 ¥498/100杯 342杯",
            'spans' => [ { 'offset' => 0, 'length' => 21 } ],
            'valueObject' => {}
          }
        ]
      end

      it 'keeps bounded diagnostic raw units without falling back to each' do
        candidate = extract.sole

        aggregate_failures do
          expect(candidate[:reference_quantity]).to include(unit_status: 'unknown', unit_code: nil, unit_raw: '杯')
          expect(candidate[:purchased_quantity]).to include(unit_status: 'unknown', unit_code: nil, unit_raw: '杯')
        end
      end
    end

    it 'does not duplicate unit_raw for known canonical units' do
      candidates = fixture_items('weighted_units_receipt')
      result = described_class.call(
        items: candidates,
        profile: ReceiptAnalysisProfiles.fetch('JPN'),
        projection: ReceiptAmountService.method(:reference_item_extension_projection)
      )

      expect(result.flat_map { |candidate| [ candidate[:reference_quantity], candidate[:purchased_quantity] ] })
        .to all(satisfy { |component| !component.key?(:unit_raw) })
    end


    context 'when a supplementary Unicode character precedes evidence' do
      let(:items) do
        content = "🍎商品\n税込 ¥498/100g 342g"
        [
          {
            'content' => content,
            'spans' => [ { 'offset' => 100, 'length' => content.encode(Encoding::UTF_16LE).bytesize / 2 } ],
            'valueObject' => {}
          }
        ]
      end

      it 'uses Azure UTF-16 code-unit coordinates for provider evidence' do
        candidate = extract.sole

        aggregate_failures do
          expect(candidate.dig(:reference_price, :evidence)).to include(
            provider_span_start: 109,
            provider_span_end: 112
          )
          expect(candidate.dig(:purchased_quantity, :evidence)).to include(
            provider_span_start: 118,
            provider_span_end: 122
          )
        end
      end


      it 'does not trust a field path whose declared UTF-16 span is shorter than its content' do
        malformed = items.first.deep_dup
        price_content = '🍎税込 ¥498/100g'
        malformed['content'] = "#{price_content}\n342g"
        malformed['spans'] = [
          { 'offset' => 100, 'length' => malformed['content'].encode(Encoding::UTF_16LE).bytesize / 2 }
        ]
        malformed['valueObject'] = {
          'Price' => {
            'content' => price_content,
            'spans' => [ { 'offset' => 100, 'length' => price_content.length } ]
          }
        }

        candidate = described_class.call(
          items: [ malformed ],
          profile: ReceiptAnalysisProfiles.fetch('JPN'),
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        ).sole

        aggregate_failures do
          expect(candidate[:validation_state]).not_to eq('valid')
          expect(candidate[:rejection_reasons]).to include('evidence_outside_item')
          expect(candidate.dig(:reference_price, :evidence, :source_field_path)).to eq('documents[0].fields.Items[0]')
        end
      end
    end

    context 'when one item is hostile between safe items' do
      let(:items) do
        safe = lambda do |offset, amount|
          content = "商品\n税込 ¥#{amount}/100g\n1g"
          {
            'content' => content,
            'spans' => [ { 'offset' => offset, 'length' => content.length } ],
            'valueObject' => {}
          }
        end
        hostile = safe.call(1_000, 200)
        hostile['content'] = "税込 ¥200/100g\xFF".b.force_encoding(Encoding::UTF_8)
        hostile['spans'] = [ { 'offset' => 1_000, 'length' => hostile['content'].bytesize } ]

        [ safe.call(0, 100), hostile, safe.call(2_000, 300) ]
      end

      it 'fails closed per item without discarding neighboring candidates' do
        expect(extract.map { |candidate| candidate[:item_index] }).to eq([ 0, 2 ])
      end
    end


    context 'with a fractional countable quantity' do
      let(:items) do
        [
          {
            'content' => "商品\n税込 ¥100/1個 1.5個",
            'spans' => [ { 'offset' => 0, 'length' => 19 } ],
            'valueObject' => {}
          },
          {
            'content' => "商品\n税込 ¥100/1.5個 1個",
            'spans' => [ { 'offset' => 100, 'length' => 19 } ],
            'valueObject' => {}
          }
        ]
      end

      it 'enforces the catalog granularity for each pricing role' do
        candidates = extract

        aggregate_failures do
          expect(candidates.fetch(0)).to include(
            validation_state: 'unsupported',
            rejection_reasons: include('invalid_purchased_quantity')
          )
          expect(candidates.fetch(1)).to include(
            validation_state: 'unsupported',
            rejection_reasons: include('invalid_reference_quantity')
          )
        end
      end
    end
  end
end
