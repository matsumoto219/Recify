require 'rails_helper'
require 'timeout'

RSpec.describe Ocr::ResponseParser::ReferencePricingCandidateExtractor do
  Q8_PROFILE = ReceiptAnalysisProfiles::Japan
  Q8_VALID_EXPRESSION = '税込 ¥120/100g 150g'

  def extract(items)
    described_class.call(
      items: items,
      profile: Q8_PROFILE,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
  end

  def utf16_length(text)
    text.encode(Encoding::UTF_16LE).bytesize / 2
  end

  def item_for(content: Q8_VALID_EXPRESSION, base_offset: 0, value_object: {})
    {
      'content' => content,
      'spans' => [ { 'offset' => base_offset, 'length' => utf16_length(content) } ],
      'valueObject' => value_object
    }
  end

  def valid_item(index = 0)
    item_for(base_offset: index * 50_000)
  end

  def padded_content(target_bytes, suffix: Q8_VALID_EXPRESSION)
    padding_bytes = target_bytes - suffix.bytesize - 1
    raise ArgumentError, 'target is smaller than suffix' if padding_bytes.negative?

    "#{'A' * padding_bytes} #{suffix}"
  end

  def price_field_item(field_bytes)
    price_suffix = '税込 ¥120/100g'
    price_content = padded_content(field_bytes, suffix: price_suffix)
    content = "#{price_content} 150g"

    item_for(
      content: content,
      value_object: {
        'Price' => {
          'content' => price_content,
          'spans' => [ { 'offset' => 0, 'length' => utf16_length(price_content) } ]
        }
      }
    )
  end

  def numeric_item(price: '120', reference_quantity: '100', purchased_quantity: '150')
    item_for(content: "税込 ¥#{price}/#{reference_quantity}g #{purchased_quantity}g")
  end

  describe 'hard boundaries' do
    it 'candidate item countの直前・上限・超過を同じ順序で100件に閉じる' do
      [ 99, 100, 101 ].each do |item_count|
        candidates = nil

        Timeout.timeout(2) { candidates = extract(Array.new(item_count) { |index| valid_item(index) }) }

        expected_count = [ item_count, described_class::MAX_ITEMS ].min
        aggregate_failures "item_count=#{item_count}" do
          expect(candidates.size).to eq(expected_count)
          expect(candidates.map { |candidate| candidate[:item_index] }).to eq((0...expected_count).to_a)
          expect(candidates.map { |candidate| candidate[:candidate_id] }.uniq.size).to eq(expected_count)
          expect(candidates).to all(include(validation_state: 'valid', rejection_reasons: []))
        end
      end
    end

    it 'item/field byte上限の直前と一致を受理し、超過だけをvalidにしない' do
      item_results = [ 4_095, 4_096, 4_097 ].to_h do |bytes|
        [ bytes, extract([ item_for(content: padded_content(bytes)) ]) ]
      end
      field_results = [ 511, 512, 513 ].to_h do |bytes|
        [ bytes, extract([ price_field_item(bytes) ]) ]
      end

      aggregate_failures do
        expect(item_results.fetch(4_095).sole[:validation_state]).to eq('valid')
        expect(item_results.fetch(4_096).sole[:validation_state]).to eq('valid')
        expect(item_results.fetch(4_097)).to eq([])

        expect(field_results.fetch(511).sole[:validation_state]).to eq('valid')
        expect(field_results.fetch(512).sole[:validation_state]).to eq('valid')
        expect(field_results.fetch(513).sole).to include(
          validation_state: 'unsupported',
          rejection_reasons: include('evidence_outside_item')
        )
      end
    end

    it 'provider span終端の直前と上限をbounded evidenceとして受理し、1超過を破棄する' do
      length = utf16_length(Q8_VALID_EXPRESSION)
      maximum = described_class::MAX_PROVIDER_SPAN_VALUE
      before = item_for(base_offset: maximum - length - 1)
      at = item_for(base_offset: maximum - length)
      over = item_for(base_offset: maximum - length + 1)

      before_candidate = extract([ before ]).sole
      at_candidate = extract([ at ]).sole

      aggregate_failures do
        expect(before_candidate[:validation_state]).to eq('valid')
        expect(at_candidate[:validation_state]).to eq('valid')
        expect(at_candidate.dig(:purchased_quantity, :evidence, :provider_span_end)).to eq(maximum)
        expect(extract([ over ])).to eq([])
      end
    end

    it 'component span配列の上限を超えるmetadataを走査せずpurchased evidenceへ使わない' do
      span_limit = described_class::MAX_COMPONENT_SPANS
      content = "商品 #{Q8_VALID_EXPRESSION}"
      quantity_start = utf16_length(content[0...content.index('150g')])

      build_item = lambda do |span_count|
        description_spans = Array.new(span_count - 1) { { 'offset' => 0, 'length' => 2 } }
        description_spans << { 'offset' => quantity_start, 'length' => 4 }
        item_for(
          content: content,
          value_object: {
            'Description' => {
              'content' => '商品',
              'spans' => description_spans
            }
          }
        )
      end

      below = extract([ build_item.call(span_limit - 1) ]).sole
      at = extract([ build_item.call(span_limit) ]).sole
      over = extract([ build_item.call(span_limit + 1) ]).sole

      aggregate_failures do
        expect(below[:validation_state]).to eq('valid')
        expect(at[:validation_state]).to eq('valid')
        expect(over).to include(
          validation_state: 'missing',
          rejection_reasons: include('missing_purchased_quantity', 'missing_purchased_unit'),
          purchased_quantity: nil
        )
      end
    end
  end

  describe 'malformed provider structures' do
    it 'non-array itemsとJSON scalar itemをraiseせず空またはper-item failureへ閉じる' do
      [ nil, {}, 'items', 1, true ].each do |value|
        expect(extract(value)).to eq([])
      end

      result = extract([ nil, {}, 'item', 1, false, [], valid_item(6) ])
      expect(result.map { |candidate| candidate[:item_index] }).to eq([ 6 ])
    end

    it 'nested spanの不正typeで全receiptを失敗させず、前後itemを維持する' do
      malformed_spans = [ true, false, 'span', 1, 1.5, [], { 'offset' => '0', 'length' => 4 } ]

      malformed_spans.each_with_index do |malformed_span, index|
        hostile = valid_item(1)
        hostile['valueObject'] = {
          'Description' => {
            'content' => '商品',
            'spans' => [ malformed_span ]
          }
        }

        candidates = nil
        expect { candidates = extract([ valid_item(0), hostile, valid_item(2) ]) }.not_to raise_error

        aggregate_failures "variant=#{index}" do
          expect(candidates.find { |candidate| candidate[:item_index] == 0 }).to include(validation_state: 'valid')
          expect(candidates.find { |candidate| candidate[:item_index] == 2 }).to include(validation_state: 'valid')
          middle = candidates.find { |candidate| candidate[:item_index] == 1 }
          expect(middle).to be_nil.or include(validation_state: satisfy { |state| state != 'valid' })
        end
      end
    end

    it 'negative・non-integer・over-end spanをcandidate path/evidenceへ出さない' do
      malformed = [
        { 'offset' => -1, 'length' => 10 },
        { 'offset' => 0, 'length' => -1 },
        { 'offset' => 0.5, 'length' => 10 },
        { 'offset' => 0, 'length' => '10' },
        { 'offset' => described_class::MAX_PROVIDER_SPAN_VALUE, 'length' => 1 }
      ]

      malformed.each do |span|
        item = valid_item
        item['spans'] = [ span ]
        expect { expect(extract([ item ])).to eq([]) }.not_to raise_error
      end
    end

    it 'byte上限超過contentをencoding/control scanより先に打ち切る' do
      oversized_string_class = Class.new(String) do
        def present?
          raise 'present? must not inspect an oversized OCR field'
        end

        def valid_encoding?
          raise 'valid_encoding? must not inspect an oversized OCR field'
        end
      end
      oversized_field = oversized_string_class.new(' ' * (described_class::MAX_FIELD_CONTENT_BYTES + 1))
      oversized_item = oversized_string_class.new('A' * (described_class::MAX_ITEM_CONTENT_BYTES + 1))
      field_candidate = nil
      blank_field_candidates = %w[Price Quantity Description].map do |field_name|
        extract([
          item_for(value_object: { field_name => { 'content' => '   ' } })
        ]).sole
      end

      expect do
        field_candidate = extract([
          item_for(
            value_object: {
              'Price' => {
                'content' => oversized_field,
                'spans' => [ { 'offset' => 0, 'length' => 1 } ]
              }
            }
          )
        ]).sole
      end.not_to raise_error

      aggregate_failures do
        expect(field_candidate).to include(
          validation_state: 'unsupported',
          rejection_reasons: include('evidence_outside_item')
        )
        expect(blank_field_candidates).to all(include(validation_state: 'valid', rejection_reasons: []))
        expect do
          expect(extract([
            {
              'content' => oversized_item,
              'spans' => [ { 'offset' => 0, 'length' => 1 } ],
              'valueObject' => {}
            }
          ])).to eq([])
        end.not_to raise_error
      end
    end
  end

  describe 'Unicode, token, and numeric traps' do
    it 'CR/LF/NEL/LS/PS越しのunstructured quantityをsame-line evidenceにしない' do
      [ "\r", "\n", "\u0085", "\u2028", "\u2029" ].each do |separator|
        candidates = extract([ item_for(content: "税込 ¥120/100g#{separator}150g") ])

        aggregate_failures separator.dump do
          expect(candidates).to all(satisfy { |candidate| candidate[:validation_state] != 'valid' })
          expect(candidates.filter_map { |candidate| candidate[:purchased_quantity] }).to eq([])
        end
      end
    end

    it 'line separator以外のC1 controlをmappable textとして受理しない' do
      [ "\u0080", "\u0084", "\u0086", "\u009F" ].each do |control|
        candidates = extract([ item_for(content: "税込 ¥120/100g#{control}150g") ])

        expect(candidates).to eq([]), control.dump
      end
    end

    it 'invisible Unicode format controlをmappable candidate textとして受理しない' do
      [ "\u061C", "\u202E", "\u2066", "\u200B", "\uFEFF" ].each do |control|
        candidates = extract([ item_for(content: "税込 ¥120/100g#{control}150g") ])

        expect(candidates).to eq([]), control.dump
      end
    end

    it 'structured BigDecimalをraiseせず照合し、巨大値と非有限値をfail-closedにする' do
      build_item = lambda do |amount|
        item_for(
          value_object: {
            'Price' => {
              'valueCurrency' => { 'amount' => amount }
            }
          }
        )
      end

      valid_candidate = nil
      expect { valid_candidate = extract([ build_item.call(BigDecimal('120')) ]).sole }.not_to raise_error

      aggregate_failures do
        expect(valid_candidate).to include(validation_state: 'valid', rejection_reasons: [])

        [ BigDecimal('1e100'), BigDecimal('Infinity'), BigDecimal('NaN') ].each do |amount|
          candidate = nil
          expect { candidate = extract([ build_item.call(amount) ]).sole }.not_to raise_error
          expect(candidate).to include(
            validation_state: 'ambiguous',
            rejection_reasons: include('ambiguous_reference_expression')
          )
        end
      end
    end

    it 'Description contentのspanが欠損・空・不正なら商品容量を購入数量にしない' do
      span_variants = [ nil, [], [ { 'offset' => '19', 'length' => 7 } ] ]

      span_variants.each do |spans|
        description = { 'content' => '飲料500ml' }
        description['spans'] = spans unless spans.nil?
        candidate = extract([
          item_for(
            content: '税込 120円/100ml 飲料500ml',
            value_object: { 'Description' => description }
          )
        ]).sole

        aggregate_failures spans.inspect do
          expect(candidate[:validation_state]).not_to eq('valid')
          expect(candidate[:purchased_quantity]).to be_nil
          expect(candidate[:rejection_reasons]).to include(
            'missing_purchased_quantity',
            'missing_purchased_unit'
          )
        end
      end
    end

    it 'unknown unit rawとnumeric tokenを64-byte境界でboundedにする' do
      unit_at = "#{'杯' * 21}a"
      unit_over = "#{'杯' * 21}ab"
      at_candidate = extract([ item_for(content: "税込 ¥120/100#{unit_at} 150#{unit_at}") ]).sole
      over_candidate = extract([ item_for(content: "税込 ¥120/100#{unit_over} 150#{unit_over}") ]).sole

      numeric_candidates = [ 63, 64, 65 ].to_h do |digits|
        token = '9' * digits
        [ digits, extract([ numeric_item(price: token) ]).sole ]
      end

      aggregate_failures do
        expect(at_candidate.dig(:reference_quantity, :unit_raw).bytesize).to eq(64)
        expect(at_candidate.dig(:purchased_quantity, :unit_raw).bytesize).to eq(64)
        expect(over_candidate.dig(:reference_quantity, :unit_raw)).to be_nil
        expect(over_candidate.dig(:purchased_quantity, :unit_raw)).to be_nil

        expect(numeric_candidates.fetch(63).dig(:reference_price, :amount)).to eq('9' * 63)
        expect(numeric_candidates.fetch(64).dig(:reference_price, :amount)).to eq('9' * 64)
        expect(numeric_candidates.fetch(65)[:reference_price]).to be_nil
        expect(numeric_candidates.fetch(65)[:rejection_reasons]).to include('invalid_reference_price')
      end
    end

    it 'price/quantity magnitudeとscaleの直前・上限・超過をdeterministicに分類する' do
      price_values = {
        '999999999998.999999' => 'valid',
        '999999999999' => 'valid',
        '999999999999.000001' => 'unsupported',
        '1.123456' => 'valid',
        '1.1234567' => 'unsupported'
      }
      quantity_values = {
        '9999.998' => 'valid',
        '9999.999' => 'valid',
        '10000' => 'unsupported',
        '1.001' => 'valid',
        '1.0001' => 'unsupported'
      }

      price_values.each do |value, state|
        candidate = extract([ numeric_item(price: value, reference_quantity: '1', purchased_quantity: '1') ]).sole
        expect(candidate[:validation_state]).to eq(state), "price=#{value}"
      end
      quantity_values.each do |value, state|
        reference = extract([ numeric_item(reference_quantity: value, purchased_quantity: '1') ]).sole
        purchased = extract([ numeric_item(reference_quantity: '1', purchased_quantity: value) ]).sole

        aggregate_failures "quantity=#{value}" do
          expect(reference[:validation_state]).to eq(state)
          expect(purchased[:validation_state]).to eq(state)
        end
      end
    end
  end

  describe 'deterministic bounded work' do
    it 'purchased quantityのraw match上限超過をvalid候補として採用しない' do
      package_tokens = ' x 1g' * (described_class::MAX_COMPONENT_SPANS - 2)
      content = "税込 ¥120/100g#{package_tokens} 150g 200g"

      candidate = extract([ item_for(content: content) ]).sole

      aggregate_failures do
        expect(candidate).to include(
          validation_state: 'ambiguous',
          rejection_reasons: include('ambiguous_purchased_quantity')
        )
        expect(candidate.dig(:purchased_quantity, :amount)).to eq('150')
      end
    end

    it 'reference expressionのraw matchを上限で打ち切り、超過を非validにする' do
      limit = described_class::MAX_COMPONENT_SPANS

      [ limit, limit + 1 ].each do |match_count|
        content = ('¥1/1g ' * match_count) + '150g'
        extractor = described_class.new(
          items: [ item_for(content: content) ],
          profile: Q8_PROFILE,
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        )
        build_calls = 0
        allow(extractor).to receive(:build_reference_match).and_wrap_original do |original, *arguments, **keywords|
          build_calls += 1
          original.call(*arguments, **keywords)
        end

        candidate = extractor.call.sole

        aggregate_failures "match_count=#{match_count}" do
          expect(build_calls).to eq(limit)
          expect(candidate).to include(
            validation_state: 'ambiguous',
            rejection_reasons: include('ambiguous_reference_expression')
          )
        end
      end
    end

    it '最大byteのdense reference expressionを100 itemでも固定match数で処理する' do
      reference_token = '¥1/1g '
      suffix = ' 150g'
      repeat_count = (described_class::MAX_ITEM_CONTENT_BYTES - suffix.bytesize) / reference_token.bytesize
      padding_bytes = described_class::MAX_ITEM_CONTENT_BYTES - (reference_token.bytesize * repeat_count) - suffix.bytesize
      dense_content = (reference_token * repeat_count) + ('A' * padding_bytes) + suffix
      items = Array.new(described_class::MAX_ITEMS) do |index|
        item_for(content: dense_content, base_offset: index * 50_000)
      end
      extractor = described_class.new(
        items: items,
        profile: Q8_PROFILE,
        projection: ReceiptAmountService.method(:reference_item_extension_projection)
      )
      build_calls = 0
      allow(extractor).to receive(:build_reference_match).and_wrap_original do |original, *arguments, **keywords|
        build_calls += 1
        original.call(*arguments, **keywords)
      end
      candidates = nil

      Timeout.timeout(2) { candidates = extractor.call }

      aggregate_failures do
        expect(dense_content.bytesize).to eq(described_class::MAX_ITEM_CONTENT_BYTES)
        expect(build_calls).to be <= described_class::MAX_ITEMS * described_class::MAX_COMPONENT_SPANS
        expect(candidates.size).to eq(described_class::MAX_ITEMS)
        expect(candidates).to all(include(
          validation_state: 'ambiguous',
          rejection_reasons: include('ambiguous_reference_expression')
        ))
      end
    end

    it '最大byteのdense quantity tokenを100 itemでも固定match数で処理する' do
      prefix = '税込 ¥120/100g '
      remaining_bytes = described_class::MAX_ITEM_CONTENT_BYTES - prefix.bytesize
      dense_content = prefix + ('1g ' * ((remaining_bytes / 3) + 1)).byteslice(0, remaining_bytes)
      items = Array.new(described_class::MAX_ITEMS) do |index|
        item_for(content: dense_content, base_offset: index * 50_000)
      end
      candidates = nil

      Timeout.timeout(2) { candidates = extract(items) }

      aggregate_failures do
        expect(dense_content.bytesize).to eq(described_class::MAX_ITEM_CONTENT_BYTES)
        expect(candidates.size).to eq(described_class::MAX_ITEMS)
        expect(candidates.map { |candidate| candidate[:candidate_id] }.uniq.size).to eq(candidates.size)
        expect(candidates).to all(satisfy do |candidate|
          !candidate.key?(:pricing_source_kind) && candidate[:rejection_reasons].size <= 8
        end)
      end
    end

    it 'duplicate/partial parent spanで双方のcandidateをambiguousのまま維持する' do
      duplicate = [ item_for(base_offset: 0), item_for(base_offset: 0) ]
      partial = [ item_for(base_offset: 0), item_for(base_offset: 10) ]

      [ duplicate, partial ].each do |items|
        candidates = extract(items)

        aggregate_failures items.map { |item| item.dig('spans', 0, 'offset') }.inspect do
          expect(candidates.map { |candidate| candidate[:item_index] }).to eq([ 0, 1 ])
          expect(candidates).to all(include(
            validation_state: 'ambiguous',
            rejection_reasons: include('ambiguous_reference_expression')
          ))
        end
      end
    end

    it 'fixed-seed semantic trapsを並べ替えてもpackage/adjacent evidenceをvalidにしない' do
      random = Random.new(20_260_815)
      traps = [ '500ml入り', '2袋 x 100g', '約100g', '100-120g', 'gross 100g', 'tare 100g', "\n150g" ]
      items = Array.new(42) do |index|
        separator = [ ' ', '  ', "\t" ].sample(random: random)
        trap = traps.sample(random: random)
        item_for(content: "税込 ¥120/100g#{separator}#{trap}", base_offset: index * 10_000)
      end

      first = nil
      Timeout.timeout(2) { first = extract(items) }
      second = extract(items.map(&:deep_dup))

      aggregate_failures do
        expect(second).to eq(first)
        expect(first).to all(satisfy { |candidate| candidate[:validation_state] != 'valid' })
        expect(first).to all(satisfy { |candidate| candidate[:rejection_reasons].size <= 8 })
      end
    end

    it 'item identity検証でitem間のquadratic overlap比較を行わない' do
      item_count = described_class::MAX_ITEMS
      datasets = {
        distinct: Array.new(item_count) { |index| valid_item(index) },
        duplicate: Array.new(item_count) { item_for(base_offset: 0) }
      }

      datasets.each do |kind, items|
        extractor = described_class.new(
          items: items,
          profile: Q8_PROFILE,
          projection: ReceiptAmountService.method(:reference_item_extension_projection)
        )
        overlap_checks = 0
        allow(extractor).to receive(:ranges_overlap?).and_wrap_original do |original, *arguments|
          overlap_checks += 1
          original.call(*arguments)
        end

        candidates = nil
        Timeout.timeout(2) { candidates = extractor.call }

        aggregate_failures kind do
          expect(candidates.size).to eq(item_count)
          expect(overlap_checks).to eq(0)
          expected_state = kind == :duplicate ? 'ambiguous' : 'valid'
          expect(candidates).to all(include(validation_state: expected_state))
        end
      end
    end
  end
end
