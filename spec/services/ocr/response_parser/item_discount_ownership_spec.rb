require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  def item_discount_response(
    header: [ 'K2' ],
    summary: [ '小計', '926', '合計 926円' ],
    per_unit_note: '(単品 -75)',
    total_marker: '',
    first_discount_interstitial: nil,
    first_discount_target_component_indexes: []
  )
    first_block = [ '検証品A', '¥410', '操作割引07', '30%' ]
    first_block.concat(Array(first_discount_interstitial))
    first_block << '-123'
    blocks = [
      first_block,
      [ '検証品B', '¥410', '操作割引07', '30%', '-123' ],
      [ '検証K2品', '¥502', '(@251×2個)', '操作割引07', '30%', per_unit_note, '-150' ]
    ]
    blocks.each { |block| block[1] += total_marker }
    content = +''
    lines = []
    append_line = lambda do |text|
      line = { 'content' => text, 'spans' => [ { 'offset' => content.length, 'length' => text.length } ] }
      content << "#{text}\n"
      lines << line
      line
    end
    header.each(&append_line)
    items = blocks.each_with_index.map do |block, index|
      start = content.length
      item_lines = block.map(&append_line)
      amount = index == 2 ? 502 : 410
      description_lines = [ item_lines.first ]
      if index.zero?
        description_lines.concat(
          first_discount_target_component_indexes.map { |offset| item_lines.fetch(4 + offset) }
        )
      end
      description = description_lines.map { |line| line.fetch('content') }.join("\n")
      {
        'content' => block.join("\n"),
        'spans' => [ { 'offset' => start, 'length' => content.length - start - 1 } ],
        'valueObject' => {
          'Description' => {
            'content' => description,
            'valueString' => description,
            'spans' => description_lines.flat_map { |line| line.fetch('spans').map(&:deep_dup) }
          },
          'TotalPrice' => { 'valueCurrency' => { 'amount' => amount }, **item_lines[1] }
        }
      }
    end
    summary.each(&append_line)
    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => 'textElements',
        'content' => content,
        'pages' => [ { 'pageNumber' => 1, 'lines' => lines } ],
        'documents' => [ { 'fields' => { 'Items' => { 'valueArray' => items } } } ]
      }
    }
  end

  def calculation_discounts(response)
    parser = described_class.new(response:)
    details = nil
    allow(parser).to receive(:extract_discount_details_by_item_index).and_wrap_original do |method, *arguments|
      details = method.call(*arguments)
    end
    parser.call
    details.values.filter_map { |detail| detail[:calculation_mode_discount] }
  end

  def separated_discount_response(side: :left, gap_text: '7')
    texts = [ '検証品', '¥500', '操作割引07', '30%', gap_text, '(単品 -75)', '-150' ]
    content = +''
    words = []
    lines = texts.map.with_index do |text, index|
      left = index == 4 ? (side == :left ? 20 : 700) : 250
      top = 20 + index * 30
      polygon = [ left, top, left + 100, top, left + 100, top + 20, left, top + 20 ]
      span = { 'offset' => content.length, 'length' => text.length }
      words << { 'content' => text, 'span' => span.dup, 'polygon' => polygon.dup }
      content << "#{text}\n"
      { 'content' => text, 'spans' => [ span ], 'polygon' => polygon }
    end
    first_span = lines[3]['spans'].sole
    first_end = first_span['offset'] + first_span['length']
    last_start = lines[5]['spans'].sole['offset']
    item = {
      'content' => texts.values_at(0, 1, 2, 3, 5, 6).join("\n"),
      'spans' => [ { 'offset' => 0, 'length' => first_end }, { 'offset' => last_start, 'length' => content.length - last_start - 1 } ],
      'boundingRegions' => [ { 'pageNumber' => 1, 'polygon' => [ 200, 10, 600, 10, 600, 240, 200, 240 ] } ],
      'valueObject' => {
        'Description' => { 'valueString' => texts.first, **lines.first },
        'TotalPrice' => { 'valueCurrency' => { 'amount' => 500 }, **lines[1] }
      }
    }
    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => 'textElements',
        'content' => content,
        'pages' => [ { 'pageNumber' => 1, 'width' => 1000, 'height' => 1000, 'unit' => 'pixel', 'lines' => lines, 'words' => words } ],
        'documents' => [ { 'fields' => { 'Items' => { 'valueArray' => [ item ] } } } ]
      }
    }
  end

  it '商品名の一部と同じheaderを割引対象にせずprovider parent内の各割引を保持する' do
    [ [], [ 'K2' ], [ 'K2', '30%' ] ].each do |header|
      result = described_class.new(response: item_discount_response(header:)).call

      expect(result.dig(:candidates, :items).map { |item| item.slice(:original_line_total, :discount_amount, :line_total) }).to eq([
        { original_line_total: 410, discount_amount: 123, line_total: 287 },
        { original_line_total: 410, discount_amount: 123, line_total: 287 },
        { original_line_total: 502, discount_amount: 150, line_total: 352 }
      ])
    end
  end

  it '単品値引注記を明細全体の値引きとして加算せず印字された行割引額を維持する' do
    result = described_class.new(response: item_discount_response).call

    expect(result.dig(:candidates, :items).last).to include(discount_amount: 150, line_total: 352)
    expect(result.dig(:candidates, :adjustment_candidates)).to be_empty
  end

  it '割引前TotalPriceと連続する複数行割引をexact component proofへする' do
    discounts = calculation_discounts(item_discount_response)

    expect(discounts.size).to eq(3)
    expect(discounts).to all(include(
      printed_total_stage: 'before_item_discount',
      rate: '0.3',
      evidence: include(:amount, :rate)
    ))
    expect(discounts.last[:amount]).to eq('150')
  end

  it '既存profileの税markerを金額sourceへ混ぜず前後を確定する' do
    expect(calculation_discounts(item_discount_response(total_marker: '※')).size).to eq(3)
    expect(calculation_discounts(item_discount_response(total_marker: 'unknown'))).to be_empty
  end

  it '割引block外のpage line順ではなくblock内の連続性を検証する' do
    response = item_discount_response
    lines = response.dig('analyzeResult', 'pages', 0, 'lines')
    lines.insert(3, lines.first.deep_dup)

    expect(calculation_discounts(response).size).to eq(3)
  end

  it '割引block内へ別page lineが割り込めば連続proofを作らない' do
    response = item_discount_response
    lines = response.dig('analyzeResult', 'pages', 0, 'lines')
    lines.insert(5, lines.first.deep_dup)

    expect(calculation_discounts(response).size).to eq(2)
  end

  it 'provider parent内の無関係な注記を跨いでも同じ明細の割引所有権を維持する' do
    result = described_class.new(
      response: item_discount_response(first_discount_interstitial: '適用案内')
    ).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ 123, 123, 150 ])
  end

  it 'provider parent内に別明細の商品名が現れても割引を別明細へ付け替えない' do
    result = described_class.new(
      response: item_discount_response(first_discount_interstitial: '検証品B')
    ).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ nil, 123, 150 ])
  end

  it 'provider Description componentが一意に示す明細だけへ割引を付け替える' do
    result = described_class.new(
      response: item_discount_response(
        first_discount_interstitial: '検証品B',
        first_discount_target_component_indexes: [ 0 ]
      )
    ).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ nil, 246, 150 ])
  end

  it 'provider Description componentのspanが改変された場合は割引を付け替えない' do
    response = item_discount_response(
      first_discount_interstitial: '検証品B',
      first_discount_target_component_indexes: [ 0 ]
    )
    description = response.dig(
      'analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray', 0,
      'valueObject', 'Description'
    )
    description.fetch('spans').last['offset'] += 1

    result = described_class.new(response:).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ nil, 123, 150 ])
  end

  it 'invalidな対象行の後にvalid Description componentが現れても割引を復活させない' do
    result = described_class.new(
      response: item_discount_response(
        first_discount_interstitial: [ '検証品B', '検証品B' ],
        first_discount_target_component_indexes: [ 1 ]
      )
    ).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ nil, 123, 150 ])
  end

  it '同じdiscount block内の複数Description targetをfail-closedにする' do
    result = described_class.new(
      response: item_discount_response(
        first_discount_interstitial: [ '検証品B', '検証K2品' ],
        first_discount_target_component_indexes: [ 0, 1 ]
      )
    ).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ nil, 123, 150 ])
  end

  it '対応明細がないDescription targetを現在のparentへ適用しない' do
    result = described_class.new(
      response: item_discount_response(
        first_discount_interstitial: '未登録対象',
        first_discount_target_component_indexes: [ 0 ]
      )
    ).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ nil, 123, 150 ])
  end

  [ :left, :right ].each do |side|
    it "親fragment外の#{side}領域にある行だけが挟まる場合は割引proofを保持する" do
      response = separated_discount_response(side:)

      expect(calculation_discounts(response)).to contain_exactly(include(printed_total_stage: 'before_item_discount', amount: '150', rate: '0.3'))
    end
  end

  it '外部領域の行を数字や店舗語彙で判別しない' do
    expect(calculation_discounts(separated_discount_response(gap_text: '外部注記'))).not_to be_empty
  end

  {
    missing_polygon: ->(page) { page['lines'][4].delete('polygon') },
    touching_parent: ->(page) { page['lines'][4]['polygon'] = [ 100, 140, 200, 140, 200, 160, 100, 160 ] },
    overlapping_parent: ->(page) { page['lines'][4]['polygon'] = [ 100, 140, 201, 140, 201, 160, 100, 160 ] },
    word_inside_parent: ->(page) { page['words'][4]['polygon'] = [ 250, 140, 350, 140, 350, 160, 250, 160 ] },
    word_touching_parent: ->(page) { page['words'][4]['polygon'] = [ 100, 140, 200, 140, 200, 160, 100, 160 ] },
    word_other_side: ->(page) { page['words'][4]['polygon'] = [ 700, 140, 800, 140, 800, 160, 700, 160 ] },
    word_missing: ->(page) { page['words'].delete_at(4) },
    word_polygon_missing: ->(page) { page['words'][4].delete('polygon') },
    word_duplicate: ->(page) { page['words'].insert(4, page['words'][4].deep_dup) },
    word_span_changed: ->(page) { page['words'][4]['span']['offset'] += 1 },
    line_span_changed: ->(page) { page['lines'][4]['spans'].sole['offset'] += 1 },
    nonconvex_polygon: ->(page) { page['lines'][4]['polygon'] = [ 20, 140, 120, 160, 120, 140, 20, 160 ] },
    nonfinite_polygon: ->(page) { page['lines'][4]['polygon'][0] = Float::INFINITY },
    different_page: ->(page) { page['pageNumber'] = 2 },
    oversized_dimension: ->(page) { page['width'] = 10_001 },
    oversized_words: ->(page) { page['words'] = [ page['words'].first ] * 4_801 }
  }.each do |name, mutation|
    it "非連続割引blockの#{name}はproofへ昇格しない" do
      response = separated_discount_response
      mutation.call(response.dig('analyzeResult', 'pages', 0))

      expect(calculation_discounts(response)).to be_empty
    end
  end

  it 'TotalPriceのcomponent span破損とparent overlapからproofを作らない' do
    response = item_discount_response
    items = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray')
    items.first.dig('valueObject', 'TotalPrice', 'spans', 0)['offset'] += 1
    expect(calculation_discounts(response).size).to eq(2)

    items[1]['spans'] = items.first['spans'].deep_dup
    expect(calculation_discounts(response)).to be_empty
  end

  it '個数と単品値引額の数式注記は行割引額の代わりに使わない' do
    result = described_class.new(response: item_discount_response(per_unit_note: '2コ×単-75')).call

    expect(result.dig(:candidates, :items).last).to include(discount_amount: 150, line_total: 352)
    expect(result.dig(:candidates, :items).last[:discount_source_refs].pluck(:amount)).to eq([ 75, 150 ])
    expect(result.dig(:candidates, :adjustment_candidates)).to be_empty
  end

  it '小計と値が別行でも小計値引を直前商品へ重複適用しない' do
    response = item_discount_response(summary: [ '小計', '926', '小計値引 -100', '合計 826円' ])
    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).map { |item| item[:discount_amount] }).to eq([ 123, 123, 150 ])
    expect(result.dig(:candidates, :adjustment_candidates)).to contain_exactly(
      include(source_text: '小計値引 -100', amount: 100)
    )
  end

  it '近くに割引率だけがある場合は調整の税率根拠にしない' do
    response = item_discount_response(summary: [ '小計', '926', 'クーポン -100', '合計 826円' ])
    result = described_class.new(response: response).call
    coupon = result.dig(:candidates, :adjustment_candidates).find { |candidate| candidate[:source_text] == 'クーポン -100' }

    expect(coupon).not_to be_nil
    expect(coupon[:tax_rate_hint]).to be_nil
  end

  it 'parent spanが重複する明細は商品名部分一致のfallbackへ戻さない' do
    response = item_discount_response
    items = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray')
    items[1]['spans'] = items[0]['spans'].deep_dup
    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).first(2).map { |item| item[:discount_amount] }).to eq([ nil, nil ])
  end

  it '単品注記の除外に注入profileを使い以前の固定語彙へ戻らない' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_item_discount_per_unit_note_pattern).and_return(/\AONLY\z/)

    result = described_class.new(response: item_discount_response, profile:).call

    expect(result.dig(:candidates, :items).last[:discount_amount]).to eq(75)
  end
end
