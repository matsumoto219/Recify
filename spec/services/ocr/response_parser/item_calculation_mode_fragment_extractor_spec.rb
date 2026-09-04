require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ItemCalculationModeFragmentExtractor do
  let(:profile) { ReceiptAnalysisProfiles.fetch('JPN') }

  def provider_length(text, index_type)
    index_type == 'utf16CodeUnit' ? text.encode(Encoding::UTF_16LE).bytesize / 2 : text.scan(/\X/).size
  end

  def provider_response(
    name: '検証商品乙',
    amount: '275',
    index_type: 'textElements',
    summary: false,
    name_prefix: '外8 ',
    name_suffix: '',
    total_suffix: ''
  )
    text_lines = [ '検証商品甲 ¥120', "#{name_prefix}#{name}#{name_suffix} ¥#{amount}#{total_suffix}", '検証商品丙 ¥340' ]
    text_lines << "合計 ¥#{120 + amount.to_i + 340}" if summary
    offset = 0
    words = []
    lines = text_lines.map.with_index do |text, index|
      top = 20 + index * 40
      text.to_enum(:scan, /\S+/).each do
        match = Regexp.last_match
        start = provider_length(text[0...match.begin(0)], index_type)
        length = provider_length(match[0], index_type)
        left = 20 + start * 12
        right = left + length * 12
        words << {
          'content' => match[0],
          'span' => { 'offset' => offset + start, 'length' => length },
          'polygon' => [ left, top, right, top, right, top + 24, left, top + 24 ]
        }
      end
      length = provider_length(text, index_type)
      line = {
        'content' => text,
        'spans' => [ { 'offset' => offset, 'length' => length } ],
        'polygon' => [ 20, top, 20 + length * 12, top, 20 + length * 12, top + 24, 20, top + 24 ]
      }
      offset += length + 1
      line
    end
    response = {
      'modelId' => 'prebuilt-receipt',
      'apiVersion' => '2024-11-30',
      'stringIndexType' => index_type,
      'content' => text_lines.join("\n"),
      'pages' => [
        {
          'pageNumber' => 1,
          'unit' => 'pixel',
          'width' => 1000,
          'height' => 200,
          'lines' => lines,
          'words' => words
        }
      ],
      'documents' => [ { 'fields' => { 'Items' => { 'valueArray' => [] } } } ]
    }
    response['documents'].sole['fields']['Items']['valueArray'] = [
      complete_item(response, 0, '検証商品甲', '120'),
      fragment_item(response, 1, 'TotalPrice', "¥#{amount}", amount.to_i),
      fragment_item(response, 1, 'Description', name),
      complete_item(response, 2, '検証商品丙', '340')
    ]
    [ [ 2, 'Description', "#{name_prefix}#{name}#{name_suffix}" ], [ 1, 'TotalPrice', "¥#{amount}#{total_suffix}" ] ].each do |item_index, field_name, parent_text|
      parent = response['documents'].sole['fields']['Items']['valueArray'][item_index]
      wrapper = fragment_item(response, 1, field_name, parent_text, amount.to_i)
      parent.merge!(wrapper.except('valueObject'))
    end
    if summary
      total = 120 + amount.to_i + 340
      response['documents'].sole['fields']['Total'] = fragment_item(response, 3, 'TotalPrice', "¥#{total}", total)['valueObject']['TotalPrice']
    end
    response
  end

  def fragment_item(response, line_index, field_name, text, amount = nil)
    line = response['pages'].sole['lines'][line_index]
    index_type = response['stringIndexType']
    prefix = line['content'][0...line['content'].index(text)]
    start = provider_length(prefix, index_type)
    length = provider_length(text, index_type)
    offset = line['spans'].sole['offset'] + start
    top = 20 + line_index * 40
    left = 20 + start * 12
    polygon = [ left, top, left + length * 12, top, left + length * 12, top + 24, left, top + 24 ]
    field = {
      'content' => text,
      'spans' => [ { 'offset' => offset, 'length' => length } ],
      'boundingRegions' => [ { 'pageNumber' => 1, 'polygon' => polygon } ]
    }
    if field_name == 'Description'
      field['valueString'] = text
    else
      field['valueCurrency'] = { 'amount' => amount, 'currencyCode' => 'JPY', 'currencySymbol' => '¥' }
    end
    {
      'content' => text,
      'spans' => field['spans'].deep_dup,
      'boundingRegions' => field['boundingRegions'].deep_dup,
      'valueObject' => { field_name => field }
    }
  end

  def complete_item(response, line_index, name, amount)
    line = response['pages'].sole['lines'][line_index]
    description = fragment_item(response, line_index, 'Description', name)
    total = fragment_item(response, line_index, 'TotalPrice', "¥#{amount}", amount.to_i)
    {
      'content' => line['content'],
      'spans' => line['spans'].deep_dup,
      'boundingRegions' => [ { 'pageNumber' => 1, 'polygon' => line['polygon'].deep_dup } ],
      'valueObject' => description['valueObject'].merge(total['valueObject'])
    }
  end

  def extract(response = provider_response, profile: self.profile)
    described_class.call(analyze_result: response, profile: profile)
  end

  def items(response)
    response.dig('documents', 0, 'fields', 'Items', 'valueArray')
  end

  it '同じprovider lineの相補的2fragmentだけをexplicit descriptorへ関連付ける' do
    response = provider_response
    before = response.deep_dup
    descriptor = extract(response).sole
    name_span = items(response)[2].dig('valueObject', 'Description', 'spans').sole
    total_span = items(response)[1].dig('valueObject', 'TotalPrice', 'spans').sole

    aggregate_failures do
      expect(descriptor).to include(
        source_provider: 'azure_calculation_layout',
        source_field_path: 'pages[0].lines[1]',
        structured_item_index: 2,
        structured_item_indexes: [ 1, 2 ],
        total_item_index: 1,
        owned_line_indexes: [ 1 ]
      )
      expect(descriptor[:item_identity]).to eq(
        "azure_calculation_layout_p0_name_l1_s#{name_span['offset']}_e#{name_span['offset'] + name_span['length']}_block_e#{total_span['offset'] + total_span['length']}"
      )
      expect(descriptor[:options].sole).to include(pricing_source_kind: 'explicit_line_total', source: { line_total_amount: '275' })
      expect(descriptor[:layout_item]).to include(name: '検証商品乙', price: nil, quantity: nil, line_total: 275)
      expect(descriptor.dig(:destination_evidence, :word_spans)).not_to be_empty
      expect(response).to eq(before)
    end
  end

  it 'fieldの配列順が反転しても同じ構造identityとsourceを返す' do
    response = provider_response
    original = extract(response).sole
    items(response)[1], items(response)[2] = items(response)[2], items(response)[1]
    reversed = extract(response).sole

    expect(reversed).to include(item_identity: original[:item_identity], options: original[:options], structured_item_index: 1, total_item_index: 2)
  end

  it '入力を凍結せずdocumentの文字位置索引を1回だけ構築して再利用する' do
    response = provider_response
    original_content = response['content']
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: response['stringIndexType'])
    allow(Ocr::ResponseParser::AzureStringIndexMapper).to receive(:build).and_return(mapper)
    expect(mapper).to receive(:each_index_segment).with(original_content).once.and_call_original

    expect(extract(response).size).to eq(1)
    expect(response['content']).to equal(original_content)
    expect(original_content).not_to be_frozen
  end

  it '明示0円をmissingや単価へ変えない' do
    descriptor = extract(provider_response(amount: '0')).sole

    expect(descriptor[:layout_item]).to include(price: nil, quantity: nil, line_total: 0)
    expect(descriptor[:options].sole[:source]).to eq(line_total_amount: '0')
  end

  it '保存金額の上限は許可し超過と小数は拒否する' do
    expect(extract(provider_response(amount: '999999999999')).sole[:layout_item][:line_total]).to eq(999_999_999_999)
    expect(extract(provider_response(amount: '1000000000000'))).to eq([])
    expect(extract(provider_response(amount: '275.5'))).to eq([])
  end

  %w[textElements utf16CodeUnit].each do |index_type|
    it "#{index_type}の結合文字・surrogate境界を正確に保つ" do
      response = provider_response(name: "検証e\u0301😀", index_type: index_type)
      descriptor = extract(response).sole
      expected = items(response)[2].dig('valueObject', 'Description', 'spans').sole

      expect(descriptor[:destination_evidence]).to include(
        provider_span_start: expected['offset'],
        provider_span_end: expected['offset'] + expected['length']
      )
    end
  end

  it '同じ行に第三のparentがある場合は結合しない' do
    response = provider_response
    items(response) << items(response)[2].deep_dup

    expect(extract(response)).to eq([])
  end

  it 'parent同士のspanが重なる場合は結合しない' do
    response = provider_response
    line = response['pages'].sole['lines'][1]
    items(response)[2]['spans'] = line['spans'].deep_dup
    items(response)[2]['content'] = line['content']
    items(response)[2]['boundingRegions'].sole['polygon'] = line['polygon'].deep_dup

    expect(extract(response)).to eq([])
  end

  it 'provider parentに属さないprefixを商品根拠として利用しない' do
    response = provider_response
    parent = items(response)[2]
    child = parent['valueObject']['Description']
    parent['content'] = child['content']
    parent['spans'] = child['spans'].deep_dup
    parent['boundingRegions'] = child['boundingRegions'].deep_dup

    expect(extract(response)).to eq([])
  end

  [ '別検証品 ', '合計 ', '現金 ', '275 ', '外100 ', '外8 外8 ', '外8追加 ' ].each do |prefix|
    it "Description parent内の未説明prefix #{prefix.inspect}を無視して結合しない" do
      expect(extract(provider_response(name_prefix: prefix))).to eq([])
    end
  end

  [ ' 別検証品', ' 100' ].each do |suffix|
    it "child外のsuffix #{suffix.inspect}を無視して結合しない" do
      expect(extract(provider_response(name_suffix: suffix))).to eq([])
      expect(extract(provider_response(total_suffix: suffix))).to eq([])
    end
  end

  it 'wrapperは注入されたprofileだけで検証し税率へ変換しない' do
    replacement = double(
      ocr_reference_pricing_line_group_destination_identifier_conflict_patterns: [],
      ocr_item_calculation_fragment_name_prefix_pattern: /\AHEADER[ \t]+\z/
    )

    expect(extract(provider_response, profile: replacement)).to eq([])
    descriptor = extract(provider_response(name_prefix: 'HEADER '), profile: replacement).sole
    expect(descriptor[:layout_item][:tax_rate]).to be_nil
  end

  it '注入されたprofileの非商品語彙で拒否する' do
    replacement = double(
      ocr_reference_pricing_line_group_destination_identifier_conflict_patterns: [ /検証商品乙/ ],
      ocr_item_calculation_fragment_name_prefix_pattern: profile.ocr_item_calculation_fragment_name_prefix_pattern
    )

    expect(extract(provider_response, profile: replacement)).to eq([])
  end

  it 'word重複による曖昧なcoverageを採用しない' do
    response = provider_response
    response['pages'].sole['words'].insert(1, response['pages'].sole['words'].first.deep_dup)

    expect(extract(response)).to eq([])
  end

  it '同一line内でもword polygonがfield外なら拒否する' do
    response = provider_response
    offset = items(response)[1]['spans'].sole['offset']
    word = response['pages'].sole['words'].find { |entry| entry['span']['offset'] == offset }
    word['polygon'].map!.with_index { |value, index| index.even? ? value - 10 : value }

    expect(extract(response)).to eq([])
  end

  it '非convex polygonを採用しない' do
    response = provider_response
    polygon = items(response)[1]['valueObject']['TotalPrice']['boundingRegions'].sole['polygon']
    polygon[2, 2], polygon[4, 2] = polygon[4, 2], polygon[2, 2]

    expect(extract(response)).to eq([])
  end

  it '別行のfragmentが近いだけでは結合しない' do
    response = provider_response
    items(response)[1] = fragment_item(response, 2, 'TotalPrice', '¥340', 340)

    expect(extract(response)).to eq([])
  end

  it 'merchantやsummaryのfieldに重なる行は結合しない' do
    response = provider_response
    response['documents'].sole['fields']['MerchantName'] = items(response)[2]['valueObject']['Description'].deep_dup

    expect(extract(response)).to eq([])
  end

  it 'nested payment fieldと重なる行も結合しない' do
    response = provider_response
    response['documents'].sole['fields']['Payments'] = {
      'valueArray' => [ { 'valueObject' => { 'Amount' => items(response)[1]['valueObject']['TotalPrice'].deep_dup } } ]
    }

    expect(extract(response)).to eq([])
  end

  it 'Description fragmentへ別sourceがある場合は結合しない' do
    response = provider_response
    items(response)[2]['valueObject']['Quantity'] = { 'valueNumber' => 1 }

    expect(extract(response)).to eq([])
  end

  it '同じ文字列でもstructured amountが異なる場合は結合しない' do
    response = provider_response
    items(response)[1]['valueObject']['TotalPrice']['valueCurrency']['amount'] = 276

    expect(extract(response)).to eq([])
  end

  it '商品名のvalueStringを別の文字列へ変換しない' do
    response = provider_response
    items(response)[2]['valueObject']['Description']['valueString'] = '別の検証商品'

    expect(extract(response)).to eq([])
  end

  it 'fieldがparent spanから外れる場合は結合しない' do
    response = provider_response
    items(response)[2]['spans'].sole['length'] -= 1

    expect(extract(response)).to eq([])
  end

  it 'fieldが別pageを指す場合は結合しない' do
    response = provider_response
    items(response)[1]['valueObject']['TotalPrice']['boundingRegions'].sole['pageNumber'] = 2

    expect(extract(response)).to eq([])
  end

  it 'wordが欠落している場合は結合しない' do
    response = provider_response
    offset = items(response)[1]['spans'].sole['offset']
    response['pages'].sole['words'].reject! { |word| word['span']['offset'] == offset }

    expect(extract(response)).to eq([])
  end

  it 'line contentとtop-level contentが異なる場合は結合しない' do
    response = provider_response
    response['pages'].sole['lines'][1]['content'].sub!('275', '276')

    expect(extract(response)).to eq([])
  end

  it 'polygonがない場合はspanだけで結合しない' do
    response = provider_response
    items(response)[1]['valueObject']['TotalPrice']['boundingRegions'].sole.delete('polygon')

    expect(extract(response)).to eq([])
  end

  it 'polygonが別のrowにある場合は結合しない' do
    response = provider_response
    items(response)[1]['valueObject']['TotalPrice']['boundingRegions'].sole['polygon'].map!.with_index { |value, index| index.odd? ? value + 40 : value }

    expect(extract(response)).to eq([])
  end

  [ nil, '', 'unicodeCodePoint', 1 ].each do |index_type|
    it "unsupported index type #{index_type.inspect}は推測変換しない" do
      response = provider_response
      response['stringIndexType'] = index_type

      expect(extract(response)).to eq([])
    end
  end

  it 'profileが未対応なら国別語彙へfallbackしない' do
    expect(extract(provider_response, profile: nil)).to eq([])
  end

  it 'provider modelとAPI versionが対応外なら拒否する' do
    response = provider_response
    response['modelId'] = 'unknown'
    expect(extract(response)).to eq([])
    response['modelId'] = 'prebuilt-receipt'
    response['apiVersion'] = 'unknown'
    expect(extract(response)).to eq([])
  end

  it 'item上限超過を切り捨てて採用しない' do
    response = provider_response
    items(response).concat(Array.new(101) { items(response).first.deep_dup })

    expect(extract(response)).to eq([])
  end

  it 'page数とline数とword数の上限超過を拒否する' do
    [ [ 'pages', 2 ], [ 'lines', 151 ], [ 'words', 4_801 ] ].each do |key, count|
      response = provider_response
      entries = key == 'pages' ? response[key] : response['pages'].sole[key]
      entries.concat(Array.new(count) { entries.first.deep_dup })

      expect(extract(response)).to eq([])
    end
  end

  it '過剰にnestedされたdocument fieldを拒否する' do
    response = provider_response
    field = { 'valueString' => 'synthetic' }
    6.times { field = { 'valueObject' => { 'Nested' => field } } }
    response['documents'].sole['fields']['Additional'] = field

    expect(extract(response)).to eq([])
  end

  it 'page範囲外と非有限polygonを拒否する' do
    [ -1, 10_001, Float::INFINITY ].each do |coordinate|
      response = provider_response
      items(response)[1]['valueObject']['TotalPrice']['boundingRegions'].sole['polygon'][0] = coordinate

      expect(extract(response)).to eq([])
    end
  end

  it 'negative offsetとoverflow spanでraiseしない' do
    [ -1, 10_000_001 ].each do |offset|
      response = provider_response
      items(response)[1]['spans'].sole['offset'] = offset

      expect(extract(response)).to eq([])
    end
  end

  it 'invalid encodingとcontrol文字を拒否する' do
    [ "\xFF".b.force_encoding(Encoding::UTF_8), "\u0000" ].each do |suffix|
      response = provider_response
      response['content'] += suffix

      expect(extract(response)).to eq([])
    end
  end

  context 'parserと非同期snapshotへの統合' do
    def parse_fragments(response = provider_response(summary: true))
      Ocr::ResponseParser.new(response: { 'analyzeResult' => response }, provider: :fixture).call
    end

    it '相補fragmentだけを1行へ戻し他Itemのsource identityとsummaryを保持する' do
      response = provider_response(summary: true)
      before = response.deep_dup
      result = parse_fragments(response)
      extracted_items = result.dig(:candidates, :items)
      candidates = result.dig(:candidates, :item_calculation_mode_candidates)

      aggregate_failures do
        expect(result[:success]).to be(true)
        expect(extracted_items.size).to eq(3)
        expect(extracted_items.pluck(:line_total)).to eq([ 120, 275, 340 ])
        expect(extracted_items[1]).to include(raw_text: '検証商品乙', price: nil, quantity: nil, tax_rate: nil)
        expect(candidates.pluck(:item_index)).to contain_exactly(0, 2, 3)
        expect(candidates.select { |candidate| candidate[:source_provider] == 'azure_structured' }.pluck(:item_index)).to eq([ 0, 3 ])
        expect(extracted_items[1][:ocr_item_identity]).to eq(extract(response).sole[:item_identity])
        expect(result.dig(:candidates, :total_amount)).to eq(735)
        expect(response).to eq(before)
      end
    end

    it '保存snapshotは同じexplicit proposalをrehydrateしruntime polygonやwordを複製しない' do
      result = parse_fragments
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
      rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(JSON.parse(JSON.generate(snapshot))).deep_symbolize_keys
      proposals = snapshot.dig('adoption_proposals', 'item_calculation_modes')

      expect(proposals&.size).to eq(3)
      fragment = proposals.find { |proposal| proposal['source_provider'] == 'azure_calculation_layout' }
      expect(fragment['options'].sole['source']).to eq('line_total_amount' => '275')
      expect(fragment['options'].sole['pricing_source_kind']).to eq('explicit_line_total')
      expect(JSON.generate(fragment)).not_to match(/polygon|word_spans|検証商品/)
      expect(rehydrated.dig(:candidates, :items).pluck(:ocr_item_identity)).to eq(result.dig(:candidates, :items).pluck(:ocr_item_identity))
      expect(Receipts::Processing::Contracts::ItemCalculationModeProposalSet.from_snapshot(proposals, ocr_snapshot: snapshot)).to eq(proposals)
    end

    it '旧snapshotのfragment数とAI indexをrehydrate時に変更しない' do
      allow(described_class).to receive(:call).and_return([])
      original = parse_fragments
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(original)
      before = snapshot.deep_dup
      expect(described_class).not_to receive(:call)

      rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot).deep_symbolize_keys

      expect(rehydrated.dig(:candidates, :items).size).to eq(4)
      expect(rehydrated.dig(:candidates, :items).pluck(:ocr_item_identity)).to eq(original.dig(:candidates, :items).pluck(:ocr_item_identity))
      expect(snapshot).to eq(before)
    end

    it '保存したOCR snapshotから3明細のexplicit sourceを確定し同じrunのretryで変更しない' do
      ocr_result = parse_fragments
      expect(ocr_result.dig(:candidates, :items)[1][:tax_rate]).to be_nil
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = Receipts::Processing.start(receipt:, source: 'upload').run
      Receipts::Processing.record_ocr_snapshot(run, ocr_result)
      Receipts::Processing.record_finalize_decision(
        run,
        Receipts::Processing::Contracts::FinalizeDecision.new(
          finalize_strategy: 'ocr_only',
          error_code: nil,
          error_message: nil,
          receipt_attributes: {},
          ocr_result: nil,
          ai_result: nil,
          metadata: {}
        )
      )

      expect(Receipts::Processing.run_finalize(run.reload).next_step).to eq(:done)
      persisted_items = receipt.reload.receipt_items.order(:position_index)
      expect(persisted_items.pluck(:pricing_source_kind)).to eq(Array.new(3, 'explicit_line_total'))
      expect(persisted_items.pluck(:position_index)).to eq([ 1, 2, 3 ])
      expect(persisted_items.pluck(:original_line_total)).to eq([ 120, 275, 340 ])
      expect(persisted_items.pluck(:line_total)).to eq([ 120, 275, 340 ])
      expect(persisted_items.pluck(:price)).to eq([ nil, nil, nil ])
      expect(receipt.total_amount).to eq(735)
      before = persisted_items.map(&:attributes)
      status = receipt.status

      expect(Receipts::Processing.run_finalize(run.reload).next_step).to eq(:skipped)
      expect(receipt.reload.receipt_items.order(:position_index).map(&:attributes)).to eq(before)
      expect(receipt.status).to eq(status)
      expect(receipt.total_amount).to eq(735)
    ensure
      receipt&.image&.purge
    end

    it '同じparentを消費するdescriptorが重複した場合はfragmentを結合しない' do
      response = provider_response(summary: true)
      descriptor = extract(response).sole
      allow(described_class).to receive(:call).and_return([ descriptor, descriptor.deep_dup ])

      result = parse_fragments(response)

      expect(result.dig(:candidates, :items).size).to eq(4)
      expect(result.dig(:candidates, :item_calculation_mode_candidates).pluck(:item_index)).to eq([ 0, 3 ])
      expect(result.dig(:candidates, :total_amount)).to eq(735)
    end

    [ 1, 2 ].each do |discount_index|
      it "fragment #{discount_index}へ既に帰属した割引を置換で失わない" do
        parser = Ocr::ResponseParser.new(response: { 'analyzeResult' => provider_response(summary: true) }, provider: :fixture)
        discount = { amount: 20, rate: nil, original_line_total: 275, source_refs: [] }
        allow(parser).to receive(:extract_discount_details_by_item_index).and_return(discount_index => discount)

        result = parser.call

        expect(result.dig(:candidates, :items).size).to eq(4)
        expect(result.dig(:candidates, :items)[discount_index]).to include(discount_amount: 20, line_total: 255)
        expect(result.dig(:candidates, :item_calculation_mode_candidates).pluck(:item_index)).to eq([ 0, 3 ])
      end
    end

    it 'fragment復元でspanのない既存summaryと税詳細を破棄しない' do
      response = provider_response(summary: true)
      fields = response['documents'].sole['fields']
      fields['Total'] = { 'valueCurrency' => { 'amount' => 735, 'currencyCode' => 'JPY' } }
      fields['Subtotal'] = { 'valueCurrency' => { 'amount' => 681, 'currencyCode' => 'JPY' } }
      fields['TotalTax'] = { 'valueCurrency' => { 'amount' => 54, 'currencyCode' => 'JPY' } }
      fields['TaxDetails'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Amount' => { 'valueCurrency' => { 'amount' => 54, 'currencyCode' => 'JPY' } },
              'NetAmount' => { 'valueCurrency' => { 'amount' => 681, 'currencyCode' => 'JPY' } },
              'Rate' => { 'valueNumber' => 0.08 }
            }
          }
        ]
      }
      allow(described_class).to receive(:call).and_return([])
      baseline = parse_fragments(response)
      allow(described_class).to receive(:call).and_call_original

      result = parse_fragments(response)

      expect(result.dig(:candidates, :items).size).to eq(3)
      expect(result[:candidates].slice(:subtotal_amount, :tax_amount, :total_amount, :tax_rate, :tax_details)).to eq(
        baseline[:candidates].slice(:subtotal_amount, :tax_amount, :total_amount, :tax_rate, :tax_details)
      )
      expect(result[:candidates]).to include(subtotal_amount: 681, tax_amount: 54, total_amount: 735)
      expect(result.dig(:candidates, :tax_details).sole).to include(amount: 54, net_amount: 681)
    end

    it 'document Totalがfragmentに直接重なる場合はitem金額として借用しない' do
      response = provider_response(summary: true)
      response['documents'].sole['fields']['Total'] = items(response)[1]['valueObject']['TotalPrice'].deep_dup

      result = parse_fragments(response)

      expect(result.dig(:candidates, :items).size).to eq(4)
      expect(result.dig(:candidates, :item_calculation_mode_candidates).pluck(:item_index)).to eq([ 0, 3 ])
      expect(result.dig(:candidates, :total_amount)).to eq(275)
    end

    it 'unsafe fragmentは従来Itemのままとし他のcomplete proposalを失わない' do
      response = provider_response(summary: true)
      items(response)[1]['valueObject']['TotalPrice']['boundingRegions'].sole.delete('polygon')
      result = parse_fragments(response)

      expect(result.dig(:candidates, :items).size).to eq(4)
      expect(result.dig(:candidates, :item_calculation_mode_candidates).pluck(:item_index)).to eq([ 0, 3 ])
      expect(result.dig(:candidates, :total_amount)).to eq(735)
    end
  end
end
