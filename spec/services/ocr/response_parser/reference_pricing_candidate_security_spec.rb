require 'rails_helper'
require 'timeout'

RSpec.describe Ocr::ResponseParser::ReferencePricingCandidateExtractor do
  PROFILE = ReceiptAnalysisProfiles::Japan

  def extract(items, projection: ReceiptAmountService.method(:reference_item_extension_projection))
    described_class.call(items: items, profile: PROFILE, projection: projection)
  end

  def fixture_items(name)
    JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)
      .dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray')
  end

  def azure_item(
    description: '量り売り商品',
    price_expression: '税抜 ¥498/100g',
    reference_price: '498',
    purchased_text: '342g',
    purchased_quantity: '342',
    purchased_unit: 'g',
    printed_total: 1_703,
    base_offset: 0
  )
    tokens = [ description, price_expression, purchased_text, printed_total.nil? ? nil : "¥#{printed_total}" ].compact
    content = tokens.join("\n")
    value_object = {
      'Description' => azure_field(
        content: description,
        container: content,
        base_offset: base_offset,
        value_key: 'valueString',
        value: description
      )
    }

    if price_expression
      value_object['Price'] = azure_field(
        content: price_expression,
        container: content,
        base_offset: base_offset,
        value_key: 'valueCurrency',
        value: { 'amount' => reference_price, 'currencyCode' => 'JPY' }
      )
    end
    if purchased_text
      value_object['Quantity'] = azure_field(
        content: purchased_text,
        container: content,
        base_offset: base_offset,
        value_key: 'valueNumber',
        value: purchased_quantity,
        occurrence: :last
      )
      if purchased_unit
        value_object['QuantityUnit'] = azure_field(
          content: purchased_text,
          container: content,
          base_offset: base_offset,
          value_key: 'valueString',
          value: purchased_unit,
          occurrence: :last
        )
      end
    end
    if printed_total
      value_object['TotalPrice'] = azure_field(
        content: "¥#{printed_total}",
        container: content,
        base_offset: base_offset,
        value_key: 'valueCurrency',
        value: { 'amount' => printed_total, 'currencyCode' => 'JPY' }
      )
    end

    {
      'content' => content,
      'spans' => [ { 'offset' => base_offset, 'length' => content.length } ],
      'valueObject' => value_object,
      'confidence' => 0.99
    }
  end

  def azure_field(content:, container:, base_offset:, value_key:, value:, occurrence: :first)
    local_offset = occurrence == :last ? container.rindex(content) : container.index(content)
    raise "field content is not in item content: #{content.inspect}" unless local_offset

    {
      'content' => content,
      'spans' => [ { 'offset' => base_offset + local_offset, 'length' => content.length } ],
      value_key => value
    }
  end

  def expect_no_valid_candidate(items)
    candidates = nil

    expect { candidates = extract(items) }.not_to raise_error
    expect(candidates).to all(satisfy { |candidate| candidate[:validation_state] != 'valid' })
    candidates
  end

  def candidate_for(items)
    extract(items).sole
  end

  describe 'package content and product-name traps' do
    it 'package-only、概算・範囲・tare/gross、multi-buyをprice basisへ昇格しない' do
      traps = [
        { description: '天然水 500ml入り', price_expression: nil },
        { description: 'たまご Mサイズ 10個入', price_expression: nil },
        { description: 'たまご Mサイズ 6個入', price_expression: nil },
        { description: '乾物 2袋 x100g', price_expression: nil },
        { description: '精肉 約100g', price_expression: nil },
        { description: '精肉 100-120g', price_expression: nil },
        { description: '精肉 tare 20g gross 120g', price_expression: '¥600', reference_price: '600' },
        { description: '対象商品 2個で300円', price_expression: nil },
        { description: 'ジュース100% 500ml', price_expression: '¥98', reference_price: '98' }
      ]
      items = traps.each_with_index.map do |attributes, index|
        azure_item(**attributes, purchased_text: nil, printed_total: 300 + index, base_offset: index * 1_000)
      end

      expect(extract(items)).to eq([])
    end

    it '既存のunusual・discount・long fixtureでもpackage/product nameを候補化しない' do
      unusual = fixture_items('unusual_units_receipt')
      discount = fixture_items('discount_heavy_receipt')
      long = fixture_items('long_receipt')

      unusual_package_indexes = [ *0..6, *9..19 ]
      long_package_indexes = [ 0, 3, 4, 28, 29, 30, 31, 32 ]

      aggregate_failures do
        expect(extract(unusual.values_at(*unusual_package_indexes))).to eq([])
        expect(extract(discount)).to eq([])
        expect(extract(long.values_at(*long_package_indexes))).to eq([])
      end
    end

    it 'weighted fixtureだけがsame-item reference expressionを持ち、1 item 1 candidateに閉じる' do
      weighted_candidates = extract(fixture_items('weighted_units_receipt'))

      aggregate_failures do
        expect(weighted_candidates.size).to eq(8)
        expect(weighted_candidates.map { |candidate| candidate[:item_index] }).to eq((0...8).to_a)
        expect(weighted_candidates.map { |candidate| candidate[:candidate_id] }.uniq.size).to eq(8)
        expect(weighted_candidates).to all(
          satisfy { |candidate| Array(candidate[:rejection_reasons]).include?('ambiguous_tax_inclusion') }
        )
      end
    end
  end

  describe 'same-item evidence and ambiguity' do
    it '隣接itemを指すprovider spanをvalid candidateとして扱わない' do
      first = azure_item(description: '隣接商品 500ml入り', price_expression: nil, purchased_text: nil, base_offset: 0)
      second = azure_item(base_offset: 1_000)
      second.dig('valueObject', 'Price', 'spans').replace(first.fetch('spans'))

      candidates = extract([ first, second ])
      second_candidate = candidates.find { |candidate| candidate[:item_index] == 1 }

      aggregate_failures do
        expect(candidates.none? { |candidate| candidate[:item_index] == 0 }).to be(true)
        expect(second_candidate).to be_present
        expect(second_candidate[:validation_state]).not_to eq('valid')
        expect(second_candidate[:rejection_reasons]).to include('evidence_outside_item')
      end
    end

    it '全component evidenceをcandidate自身のitem indexとfield pathへ束縛する' do
      candidates = extract([
        azure_item(base_offset: 0),
        azure_item(description: '量り売り商品B', base_offset: 1_000)
      ])

      candidates.each do |candidate|
        %i[reference_price reference_quantity purchased_quantity].each do |component_name|
          evidence = candidate.dig(component_name, :evidence)

          aggregate_failures "#{candidate[:candidate_id]} #{component_name}" do
            expect(evidence).to include(
              source_provider: 'azure_structured',
              item_index: candidate[:item_index]
            )
            expect(evidence[:source_field_path]).to include("Items[#{candidate[:item_index]}]")
            expect(evidence[:provider_span_end]).to be > evidence[:provider_span_start]
            unless component_name == :reference_price
              expect(candidate.fetch(component_name)).not_to have_key(:unit_raw)
            end
          end
        end
      end
    end

    it '同一itemの複数basisを1件のambiguous diagnosticにする' do
      item = azure_item(price_expression: '税抜 ¥498/100g または ¥996/200g')
      candidate = candidate_for([ item ])

      aggregate_failures do
        expect(candidate[:validation_state]).to eq('ambiguous')
        expect(candidate[:rejection_reasons]).to include('ambiguous_reference_expression')
        expect(extract([ item ])).to eq([ candidate ])
      end
    end

    it 'duplicate provider spanでもcandidateを重複生成せず順序と結果を安定化する' do
      item = azure_item
      %w[Price Quantity QuantityUnit].each do |field_name|
        spans = item.dig('valueObject', field_name, 'spans')
        spans << spans.first.deep_dup
      end

      first = extract([ item ])
      second = extract([ item.deep_dup ])

      aggregate_failures do
        expect(first.size).to eq(1)
        expect(second).to eq(first)
        expect(first.map { |candidate| candidate[:candidate_id] }).to eq(first.map { |candidate| candidate[:candidate_id] }.uniq)
      end
    end
  end

  describe 'incomplete and unsupported sources' do
    it '欠損componentを補完せずdiagnosticへ倒す' do
      cases = [
        [ azure_item(purchased_text: nil), 'missing_purchased_quantity' ],
        [ azure_item(purchased_text: '342', purchased_unit: nil), 'missing_purchased_unit' ],
        [ azure_item(price_expression: '税抜 ¥498/100', purchased_unit: 'g'), 'missing_reference_unit' ]
      ]

      cases.each do |item, reason|
        candidate = candidate_for([ item ])

        aggregate_failures reason do
          expect(candidate[:validation_state]).to eq('missing')
          expect(candidate[:rejection_reasons]).to include(reason)
          if reason == 'missing_reference_unit'
            expect(candidate.dig(:reference_quantity, :unit_status)).to eq('blank')
            expect(candidate.fetch(:reference_quantity)).not_to have_key(:unit_raw)
          elsif reason == 'missing_purchased_unit'
            expect(candidate.dig(:purchased_quantity, :unit_status)).to eq('blank')
            expect(candidate.fetch(:purchased_quantity)).not_to have_key(:unit_raw)
          end
        end
      end
    end

    it 'tax inclusion欠損・競合をreceipt profileから推測しない' do
      missing = candidate_for([ azure_item(price_expression: '¥498/100g') ])
      conflicting = candidate_for([ azure_item(price_expression: '税込 税抜 ¥498/100g') ])

      aggregate_failures do
        [ missing, conflicting ].each do |candidate|
          expect(candidate[:validation_state]).to eq('ambiguous')
          expect(candidate[:reference_price_tax_inclusion]).to eq('unknown')
          expect(candidate[:rejection_reasons]).to include('ambiguous_tax_inclusion')
        end
      end
    end

    it 'unknown reference/purchased unitをeachへfallbackしない' do
      unknown_reference = candidate_for([
        azure_item(price_expression: '税抜 ¥498/100杯', purchased_text: '342g', purchased_unit: 'g')
      ])
      unknown_purchased = candidate_for([
        azure_item(price_expression: '税抜 ¥498/100g', purchased_text: '342杯', purchased_unit: '杯')
      ])

      aggregate_failures do
        expect(unknown_reference[:validation_state]).to eq('unsupported')
        expect(unknown_reference[:rejection_reasons]).to include('unsupported_reference_unit')
        expect(unknown_reference.dig(:reference_quantity, :unit_status)).to eq('unknown')
        expect(unknown_reference.dig(:reference_quantity, :unit_code)).to be_nil
        expect(unknown_reference.dig(:reference_quantity, :unit_raw)).to eq('杯')
        expect(unknown_reference.dig(:reference_quantity, :unit_raw).bytesize).to be <= 64

        expect(unknown_purchased[:validation_state]).to eq('unsupported')
        expect(unknown_purchased[:rejection_reasons]).to include('unsupported_purchased_unit')
        expect(unknown_purchased.dig(:purchased_quantity, :unit_status)).to eq('unknown')
        expect(unknown_purchased.dig(:purchased_quantity, :unit_code)).to be_nil
        expect(unknown_purchased.dig(:purchased_quantity, :unit_raw)).to eq('杯')
        expect(unknown_purchased.dig(:purchased_quantity, :unit_raw).bytesize).to be <= 64
      end
    end

    it 'cross-dimension sourceを計算せずunsupportedへ倒す' do
      candidate = candidate_for([
        azure_item(price_expression: '税抜 ¥498/100g', purchased_text: '1L', purchased_quantity: '1', purchased_unit: 'L')
      ])

      aggregate_failures do
        expect(candidate[:validation_state]).to eq('unsupported')
        expect(candidate[:rejection_reasons]).to include('incompatible_unit_dimension')
        expect(candidate[:corroboration]).to be_nil
      end
    end
  end

  describe 'hostile text and Unicode variants' do
    it 'invalid UTF-8、NUL、C0 controlでraiseせずvalid candidateを作らない' do
      invalid_utf8 = "税抜 ¥498/100g\xFF".b.force_encoding(Encoding::UTF_8)
      variants = [ invalid_utf8, "税抜 ¥498/\0 100g", "税抜\u0001 ¥498/100g" ]

      variants.each_with_index do |hostile_text, index|
        item = azure_item(base_offset: index * 1_000)
        item['content'] = hostile_text
        item['spans'] = [ { 'offset' => index * 1_000, 'length' => hostile_text.bytesize } ]
        item.dig('valueObject', 'Price')['content'] = hostile_text
        item.dig('valueObject', 'Price')['spans'] = item.fetch('spans').deep_dup

        expect_no_valid_candidate([ item ])
      end
    end

    it 'NFKC相当の全角数字・slash・spaceをASCII表記と同じcanonical componentへ正規化する' do
      ascii = candidate_for([ azure_item ])
      unicode = candidate_for([
        azure_item(
          price_expression: "税抜\u3000￥４９８／１００ｇ",
          reference_price: '498',
          purchased_text: "３４２\u00a0ｇ",
          purchased_quantity: '342',
          purchased_unit: 'ｇ'
        )
      ])

      aggregate_failures do
        expect(unicode[:validation_state]).to eq(ascii[:validation_state])
        expect(unicode.dig(:reference_price, :amount)).to eq('498')
        expect(unicode.dig(:reference_quantity, :amount)).to eq('100')
        expect(unicode.dig(:reference_quantity, :unit_code)).to eq('gram')
        expect(unicode.dig(:purchased_quantity, :amount)).to eq('342')
        expect(unicode.dig(:purchased_quantity, :unit_code)).to eq('gram')
      end
    end

    it 'fraction/division slashやmultiplication表記をASCII price basisとして拡大解釈しない' do
      variants = [ '税抜 ¥498⁄100g', '税抜 ¥498∕100g', '税抜 ¥498×100g' ]

      variants.each do |expression|
        expect_no_valid_candidate([ azure_item(price_expression: expression) ])
      end
    end
  end

  describe 'numeric bounds and grammar' do
    it 'overprecisionとmagnitude超過を理由別にrejectする' do
      cases = [
        [ azure_item(price_expression: '税抜 ¥1.1234567/100g', reference_price: '1.1234567'), 'invalid_reference_price' ],
        [ azure_item(price_expression: '税抜 ¥1000000000000/100g', reference_price: '1000000000000'), 'reference_price_out_of_bounds' ],
        [ azure_item(price_expression: '税抜 ¥498/1.0001g'), 'invalid_reference_quantity' ],
        [ azure_item(price_expression: '税抜 ¥498/10000g'), 'reference_quantity_out_of_bounds' ],
        [ azure_item(purchased_text: '1.0001g', purchased_quantity: '1.0001'), 'invalid_purchased_quantity' ],
        [ azure_item(purchased_text: '10000g', purchased_quantity: '10000'), 'purchased_quantity_out_of_bounds' ]
      ]

      cases.each do |item, reason|
        candidate = candidate_for([ item ])

        aggregate_failures reason do
          expect(candidate[:validation_state]).not_to eq('valid')
          expect(candidate[:rejection_reasons]).to include(reason)
        end
      end
    end

    it 'NaN・Infinity・指数表記・負数をfinite decimalへ変換しない' do
      expressions = [
        [ '税抜 ¥NaN/100g', BigDecimal('NaN') ],
        [ '税抜 ¥Infinity/100g', BigDecimal('Infinity') ],
        [ '税抜 ¥1e3/100g', '1e3' ],
        [ '税抜 ¥-1/100g', '-1' ],
        [ '税抜 ¥498/1e2g', '498' ]
      ]

      expressions.each do |expression, structured_amount|
        expect_no_valid_candidate([
          azure_item(price_expression: expression, reference_price: structured_amount)
        ])
      end
    end

    it 'exact maximumとmaximum scaleを受け入れ、その直後をrejectする' do
      maximum = candidate_for([
        azure_item(
          price_expression: '税込 ¥999999999999/9999.999g',
          reference_price: '999999999999',
          purchased_text: '9999.999g',
          purchased_quantity: '9999.999',
          printed_total: nil
        )
      ])
      over = candidate_for([
        azure_item(
          price_expression: '税込 ¥999999999999.000001/9999.999g',
          reference_price: '999999999999.000001',
          purchased_text: '9999.999g',
          purchased_quantity: '9999.999',
          printed_total: nil
        )
      ])

      aggregate_failures do
        expect(maximum[:validation_state]).to eq('valid')
        expect(maximum.dig(:reference_price, :amount)).to eq('999999999999')
        expect(maximum.dig(:reference_quantity, :amount)).to eq('9999.999')
        expect(over[:validation_state]).not_to eq('valid')
        expect(over[:rejection_reasons]).to include('reference_price_out_of_bounds')
      end
    end
  end

  describe 'bounded work and side effects' do
    it '先頭100 itemだけを順序どおり処理しcandidate/reasonをboundedにする' do
      items = Array.new(105) do |index|
        azure_item(description: "量り売り商品#{index}", base_offset: index * 10_000)
      end
      candidates = nil

      Timeout.timeout(2) { candidates = extract(items) }

      aggregate_failures do
        expect(candidates.size).to eq(100)
        expect(candidates.map { |candidate| candidate[:item_index] }).to eq((0...100).to_a)
        expect(candidates.map { |candidate| candidate[:candidate_id] }.uniq.size).to eq(100)
        expect(candidates).to all(satisfy { |candidate| candidate[:rejection_reasons].size <= 8 })
      end
    end

    it '4096-byte item、512-byte field、64-byte unit境界を超える入力をvalidにしない' do
      oversized_item = azure_item(description: 'A' * 4_097)
      oversized_field = azure_item(price_expression: "#{'A' * 513} 税抜 ¥498/100g")
      oversized_unit = azure_item(
        price_expression: "税抜 ¥498/100#{'杯' * 65}",
        purchased_text: "342#{'杯' * 65}",
        purchased_unit: '杯' * 65
      )

      [ oversized_item, oversized_field, oversized_unit ].each do |item|
        candidates = expect_no_valid_candidate([ item ])
        expect(candidates.size).to be <= 1
      end
    end

    it 'DB・provider・job・logへ触れず、入力やraw payloadを出力へ漏らさない' do
      secret = 'PRIVATE-RECEIPT-PAYLOAD-DO-NOT-LOG'
      item = azure_item(description: secret)
      original = Marshal.load(Marshal.dump(item))
      sql = []
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name].to_s)

        sql << payload[:sql]
      end

      expect(Ocr::Client).not_to receive(:new)
      expect(Ai::Client).not_to receive(:new)
      expect(ReceiptOcrService).not_to receive(:call)
      expect(ReceiptAiEnrichmentService).not_to receive(:call)
      expect(ReceiptOcrJob).not_to receive(:perform_later)
      expect(ReceiptAiEnrichmentJob).not_to receive(:perform_later)
      %i[debug info warn error fatal].each do |level|
        expect(Rails.logger).not_to receive(level).with(satisfy { |message| message.to_s.include?(secret) })
      end

      candidates = nil
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        candidates = extract([ item ])
      end

      aggregate_failures do
        expect(sql).to eq([])
        expect(item).to eq(original)
        expect(candidates.to_json).not_to include(secret)
        expect(candidates.to_json).not_to include(item['content'])
        expect(candidates).to all(satisfy do |candidate|
          candidate.values_at(:reference_price, :reference_quantity, :purchased_quantity).compact.all? do |component|
            component.keys.all? { |key| %i[amount unit_code unit_status unit_raw origin evidence].include?(key) }
          end
        end)
      end
    end
  end
end
