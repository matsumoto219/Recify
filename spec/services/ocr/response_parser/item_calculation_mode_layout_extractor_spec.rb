require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ItemCalculationModeLayoutExtractor do
  let(:profile) { ReceiptAnalysisProfiles.fetch('JPN') }

  def provider_layout(text_lines, append_summary: true)
    text_lines = [ *text_lines, '合計 0円' ] if append_summary && text_lines.none? { |line| line.start_with?('合計 ', '小計 ') }
    offset = 0
    words = []
    lines = text_lines.each_with_index.map do |text, index|
      top = 20 + index * 24
      width = text.length * 10
      text.to_enum(:scan, /\S+/).each do
        match = Regexp.last_match
        left = 20 + match.begin(0) * 10
        right = left + match[0].length * 10
        words << {
          'content' => match[0],
          'span' => { 'offset' => offset + match.begin(0), 'length' => match[0].length },
          'polygon' => [ left, top, right, top, right, top + 16, left, top + 16 ]
        }
      end
      line = {
        'content' => text,
        'spans' => [ { 'offset' => offset, 'length' => text.length } ],
        'polygon' => [ 20, top, 20 + width, top, 20 + width, top + 16, 20, top + 16 ]
      }
      offset += text.length + 1
      line
    end
    {
      'modelId' => 'prebuilt-receipt',
      'apiVersion' => '2024-11-30',
      'stringIndexType' => 'textElements',
      'content' => text_lines.join("\n"),
      'pages' => [
        {
          'pageNumber' => 1,
          'unit' => 'pixel',
          'width' => 600,
          'height' => 40 + text_lines.size * 24,
          'lines' => lines,
          'words' => words
        }
      ],
      'documents' => [ { 'fields' => {} } ]
    }
  end

  def extract(lines, profile: self.profile)
    described_class.call(analyze_result: provider_layout(lines), profile: profile)
  end

  def response_with_total_fragment
    response = provider_layout([ '検証商品', '単価 @100円', '数量 1個', '明細計 100円' ])
    total_line = response['pages'].sole['lines'][-2]
    response['documents'].sole['fields']['Items'] = {
      'valueArray' => [
        {
          'spans' => total_line['spans'].deep_dup,
          'valueObject' => {
            'TotalPrice' => {
              'content' => total_line['content'],
              'spans' => total_line['spans'].deep_dup,
              'valueCurrency' => { 'amount' => 100, 'currencyCode' => 'JPY' }
            }
          }
        }
      ]
    }
    response
  end

  def response_with_name_fragment(start: 0, length: 4, split_words: true)
    response = provider_layout([ '検証商品甲(税込27%)', '単価 @100円', '数量 1個', '明細計 100円' ])
    page = response['pages'].sole
    line = page['lines'].first
    span = { 'offset' => start, 'length' => length }
    response['documents'].sole['fields']['Items'] = {
      'valueArray' => [
        {
          'spans' => [ span.deep_dup ],
          'valueObject' => {
            'Description' => {
              'content' => line['content'][start, length],
              'spans' => [ span.deep_dup ]
            }
          }
        }
      ]
    }
    if split_words
      original_word = page['words'].shift
      name_words = line['content'].each_char.map.with_index do |character, index|
        left = 20 + index * 10
        {
          'content' => character,
          'span' => { 'offset' => index, 'length' => 1 },
          'polygon' => [ left, 20, left + 10, 20, left + 10, 36, left, 36 ]
        }
      end
      raise 'unexpected name word fixture' unless original_word['content'] == line['content']

      page['words'] = name_words + page['words']
    end
    response
  end

  it 'Items欠損でも個数・固定額・明示0・金額欠損を独立blockとして保持する' do
    descriptors = extract([
      '検証商品甲(税込96%)', '単価 @257円', '数量 1個', '明細計 257円',
      '検証商品乙(税込96%)', '明細計 431円',
      '検証商品丙(税込96%)', '明細計 0円',
      '検証商品丁(税込96%)', '数量 2個', '合計 688円'
    ])

    expect(descriptors.size).to eq(4)
    expect(descriptors.map { |entry| entry[:options].map { |option| option[:pricing_source_kind] } }).to eq([
      %w[count_unit_price explicit_line_total], [ 'explicit_line_total' ], [ 'explicit_line_total' ], []
    ])
    expect(descriptors.last[:layout_item]).to include(price: nil, line_total: nil, quantity: '2')
    expect(descriptors.map { |entry| entry[:item_identity] }.uniq.size).to eq(4)
    expect(descriptors).to all(include(source_provider: 'azure_calculation_layout', structured_item_indexes: []))
  end

  it 'countとmass/volume referenceとexplicitを同時に構成する' do
    descriptors = extract([
      '検証個数品(税込1%)', '単価 @193円', '数量 3本', '明細計 579円',
      '検証量売粉(税込27%)', '税込 317円/100g', '計量 250g', '明細計 793円',
      '検証量売液(税込75%)', '税込 126円/500ml', '計量 1.5L', '明細計 378円',
      '検証固定作業(税込31%)', '明細計 503円'
    ])

    expect(descriptors.size).to eq(4)
    expect(descriptors[1][:options].first[:source]).to include(
      reference_price_amount: '317',
      reference_quantity: '100',
      reference_quantity_unit_code: 'gram',
      purchased_quantity: '250',
      purchased_quantity_unit_code: 'gram',
      reference_price_tax_inclusion: 'gross'
    )
    expect(descriptors[2][:options].first[:source]).to include(
      reference_quantity: '500',
      reference_quantity_unit_code: 'milliliter',
      purchased_quantity: '1.5',
      purchased_quantity_unit_code: 'liter'
    )
    expect(descriptors.map { |entry| entry.dig(:layout_item, :tax_rate) }).to eq(%w[0.01 0.27 0.75 0.31].map { |value| BigDecimal(value) })
  end

  it 'reference価格をper-oneへ正規化せずruntime itemへexactに保持する' do
    descriptor = extract([ '検証商品(税込27%)', '税込 317円/100g', '計量 250g', '明細計 793円' ]).sole

    expect(descriptor[:layout_item][:price]).to eq('317')
    expect(descriptor[:layout_item][:quantity]).to eq('250')
    expect(descriptor[:options].first[:source][:reference_quantity]).to eq('100')
  end

  it '明示percentの0.5を0.005として保持する' do
    descriptor = extract([ '検証商品(税込0.5%)', '明細計 100円' ]).sole

    expect(descriptor[:layout_item][:tax_rate]).to eq(BigDecimal('0.005'))
  end

  it '不正な四角形はbounding boxが正常でも拒否する' do
    response = provider_layout([ '検証商品', '明細計 100円' ])
    line = response['pages'].sole['lines'].first
    left, top, right, _, _, bottom = line['polygon']
    line['polygon'] = [ left, top, right, bottom, right, top, left, bottom ]

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it '非対応profileで日本語へfallbackしない' do
    expect(extract([ '検証商品', '明細計 100円' ], profile: ReceiptAnalysisProfiles.fetch('USA'))).to be_empty
  end

  it '注入された単価labelを使い元の日本語labelを使わない' do
    allow(profile).to receive(:ocr_item_calculation_layout_price_line_pattern).and_return(/\ACOST (?<amount>[0-9]+)円\z/)

    expect(extract([ '検証商品', 'COST 100円', '数量 2個', '明細計 200円' ]).sole[:options].first[:pricing_source_kind]).to eq('count_unit_price')
    expect(extract([ '検証商品', '単価 @100円', '数量 2個', '明細計 200円' ])).to be_empty
  end

  it '注入されたreference grammarを使い元の日本語grammarを使わない' do
    allow(profile).to receive(:ocr_item_calculation_layout_reference_line_pattern).and_return(/\ARATE (?<tax>税込) (?<amount>[0-9]+)円\/(?<quantity>[0-9]+)(?<unit>g)\z/)

    expect(extract([ '検証商品', 'RATE 税込 100円/100g', '計量 200g', '明細計 200円' ]).sole[:options].first[:pricing_source_kind]).to eq('reference_quantity_price')
    expect(extract([ '検証商品', '税込 100円/100g', '計量 200g', '明細計 200円' ])).to be_empty
  end

  it '注入されたitem-tax suffixを使い元の日本語suffixを使わない' do
    allow(profile).to receive(:ocr_item_calculation_layout_name_tax_pattern).and_return(/\A(?<name>[^\[\]]+)\[(?<tax>税込)(?<rate>[0-9]+)%\]\z/)

    expect(extract([ '検証商品[税込27%]', '明細計 100円' ]).sole[:layout_item][:tax_rate]).to eq(BigDecimal('0.27'))
    expect(extract([ '検証商品(税込27%)', '明細計 100円' ])).to be_empty
  end

  [
    [ 'fractional count price', [ '検証商品', '単価 @100.5円', '数量 2個', '明細計 201円' ] ],
    [ 'count quantity overflow', [ '検証商品', '単価 @100円', '数量 10000個', '明細計 1000000円' ] ],
    [ 'fractional count quantity', [ '検証商品', '単価 @100円', '数量 1.5個', '明細計 150円' ] ],
    [ 'amount overflow', [ '検証商品', '明細計 1000000000000円' ] ],
    [ 'unsupported unit', [ '検証商品', '税込 100円/100oz', '計量 200oz', '明細計 200円' ] ],
    [ 'dimension mismatch', [ '検証商品', '税込 100円/100g', '計量 200ml', '明細計 200円' ] ],
    [ 'duplicate tax suffix', [ '検証商品(税込1%)(税込27%)', '明細計 100円' ] ],
    [ 'package capacity', [ '検証商品500ml入り', '明細計 100円' ] ]
  ].each do |label, lines|
    it "#{label}をlayout authority候補にしない" do
      expect(extract(lines)).to be_empty
    end
  end

  it 'pagesとwordsの上限超過を拒否する' do
    response = provider_layout([ '検証商品', '明細計 100円' ])
    response['pages'] << response['pages'].first.deep_dup
    expect(described_class.call(analyze_result: response, profile:)).to be_empty

    response['pages'].pop
    response['pages'].sole['words'] = Array.new(4_801) { response['pages'].sole['words'].first.deep_dup }
    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it '商品名の重複は構造位置の異なるidentityとして区別する' do
    descriptors = extract([ '検証品', '明細計 100円', '検証品', '明細計 200円' ])

    expect(descriptors.size).to eq(2)
    expect(descriptors.map { |entry| entry[:item_identity] }.uniq.size).to eq(2)
  end

  it '同額でもunit-price行を指すTotalPriceを明細合計へ転用しない' do
    response = response_with_total_fragment
    item = response['documents'].sole['fields']['Items']['valueArray'].sole
    wrong_line = response['pages'].sole['lines'][1]
    item['spans'] = wrong_line['spans'].deep_dup
    item['valueObject']['TotalPrice']['spans'] = wrong_line['spans'].deep_dup
    item['valueObject']['TotalPrice']['content'] = wrong_line['content']

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it '同一name componentの完全なword prefixだけを持つDescriptionもfragmentとして関連付ける' do
    response = response_with_name_fragment

    descriptor = described_class.call(analyze_result: response, profile:).sole

    expect(descriptor[:structured_item_indexes]).to eq([ 0 ])
    expect(descriptor[:layout_item][:name]).to eq('検証商品甲')
    expect(descriptor[:options].first[:pricing_source_kind]).to eq('count_unit_price')
  end

  it 'Description fragmentがprovider wordの途中で切れる場合は採用しない' do
    response = response_with_name_fragment(split_words: false)

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it 'item-local tax suffixをDescription fragmentにしない' do
    response = response_with_name_fragment(start: 6, length: 2)

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  [ 'USD', nil ].each do |currency|
    it "structured通貨#{currency.inspect}をJPYとして扱わない" do
      response = response_with_total_fragment
      field = response['documents'].sole['fields']['Items']['valueArray'].sole['valueObject']['TotalPrice']
      field['valueCurrency']['currencyCode'] = currency

      expect(described_class.call(analyze_result: response, profile:)).to be_empty
    end
  end

  it 'child spanがparentの隙間にある場合は同じblockでも拒否する' do
    response = response_with_total_fragment
    item = response['documents'].sole['fields']['Items']['valueArray'].sole
    item['spans'] = response['pages'].sole['lines'].first['spans'].deep_dup

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it 'parentとchildのspan数上限を超える場合は拒否する' do
    response = response_with_total_fragment
    item = response['documents'].sole['fields']['Items']['valueArray'].sole
    item['spans'] *= 5
    expect(described_class.call(analyze_result: response, profile:)).to be_empty

    response = response_with_total_fragment
    field = response['documents'].sole['fields']['Items']['valueArray'].sole['valueObject']['TotalPrice']
    field['spans'] *= 2
    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it 'unknown fieldと過大fieldを解釈せず拒否する' do
    response = response_with_total_fragment
    item = response['documents'].sole['fields']['Items']['valueArray'].sole
    item['valueObject']['Unknown'] = item['valueObject']['TotalPrice'].deep_dup
    expect(described_class.call(analyze_result: response, profile:)).to be_empty

    response = response_with_total_fragment
    field = response['documents'].sole['fields']['Items']['valueArray'].sole['valueObject']['TotalPrice']
    field['content'] = 'x' * 513
    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it '過大なstructured unitをunit resolverへ渡さない' do
    response = response_with_total_fragment
    item = response['documents'].sole['fields']['Items']['valueArray'].sole
    quantity_line = response['pages'].sole['lines'][2]
    quantity_span = quantity_line['spans'].sole
    item['spans'].unshift(quantity_span.deep_dup)
    oversized_unit = '個' * 513
    item['valueObject']['QuantityUnit'] = {
      'content' => '個',
      'spans' => [ { 'offset' => quantity_span['offset'] + quantity_line['content'].index('個'), 'length' => 1 } ],
      'valueString' => oversized_unit
    }
    allow(profile).to receive(:resolve_quantity_unit).and_call_original
    expect(profile).not_to receive(:resolve_quantity_unit).with(oversized_unit)

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it 'page範囲外のpolygonをexact座標へ変換する前に拒否する' do
    response = provider_layout([ '検証商品', '明細計 100円' ])
    response['pages'].sole['lines'].first['polygon'][0] = Float::MAX
    extractor = described_class.new(analyze_result: response, profile:)
    allow(extractor).to receive(:convex_polygon?).and_call_original
    expect(extractor).not_to receive(:convex_polygon?).with(response['pages'].sole['lines'].first['polygon'])

    expect(extractor.call).to be_empty
  end

  it '商品名候補が折り返された場合は関連付けを推測しない' do
    expect(extract([ '検証商品', '補足名称', '単価 @100円', '数量 2個', '明細計 200円' ])).to be_empty
  end

  [
    [ 'before', [ '未対応商品', '価格未確定', '検証商品', '明細計 100円' ] ],
    [ 'between', [ '検証商品甲', '明細計 100円', '未対応商品', '価格未確定', '検証商品乙', '明細計 200円' ] ],
    [ 'after', [ '検証商品', '明細計 100円', '未対応商品', '価格未確定' ] ],
    [ 'orphan numeric', [ '検証商品', '明細計 100円', '999' ] ],
    [ 'unowned discount', [ '検証商品', '明細計 100円', '値引 27% -27円' ] ]
  ].each do |label, lines|
    it "#{label}の未所有lineを黙って捨てない" do
      expect(extract(lines)).to be_empty
    end
  end

  it '全文一致するreceipt headerから明示summaryまでをitem領域とする' do
    expect(extract([ '検証売場', '領収書', '検証商品', '明細計 100円', '小計 100円', '合計 100円' ]).size).to eq(1)
    expect(extract([ '検証売場', '領収書用紙', '検証商品', '明細計 100円' ])).to be_empty
  end

  it '複数headerを複数receiptとして拒否する' do
    expect(extract([ '領収書', '検証商品', '明細計 100円', '領収書', '検証商品', '明細計 100円' ])).to be_empty
  end

  it '明示summaryなしでは全明細領域の完全性を宣言しない' do
    response = provider_layout([ '検証商品', '明細計 100円' ], append_summary: false)

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  [ '未対応形式商品乙 300円', '300', '値引 27% -54円', '現金商品 300円', '課税商品 300円' ].each do |unowned_line|
    it "subtotal以降の未所有lineを捨てない: #{unowned_line}" do
      descriptors = extract([
        '検証商品', '単価 @100円', '数量 2個', '明細計 200円',
        '小計 200円', unowned_line, '合計 500円'
      ])

      expect(descriptors).to be_empty
    end
  end

  it '通常の税対象・税額・支払・預り・釣銭footerを明細と混同しない' do
    descriptors = extract([
      '検証商品', '単価 @100円', '数量 2個', '明細計 200円',
      '小計 200円', '消費税 2円', '合計 202円',
      '1%対象計 202円', '内税 2円', '現金 202円', 'お預り 300円', '釣銭 98円'
    ])

    expect(descriptors.size).to eq(1)
    expect(descriptors.sole[:options].first[:pricing_source_kind]).to eq('count_unit_price')
  end

  it '見出しと商品名の区別が構造上決まらないexplicit blockを採用しない' do
    expect(extract([ '検証売場', '検証商品', '明細計 200円' ])).to be_empty
  end

  it 'merchant fieldと同じspanの行を商品名として採用しない' do
    response = provider_layout([ '検証店舗', '明細計 200円' ])
    response['documents'].sole['fields']['MerchantName'] = {
      'content' => '検証店舗',
      'spans' => response['pages'].sole['lines'].first['spans']
    }

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it 'spanの異なるwordを近さだけでblockへ関連付けない' do
    response = provider_layout([ '検証商品', '明細計 200円' ])
    response['pages'].sole['words'].first['span']['offset'] += 1

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it '既存の行高半分を超えるgapではblockを関連付けない' do
    response = provider_layout([ '検証商品', '明細計 200円' ])
    page = response['pages'].sole
    page['lines'][1]['polygon'] = page['lines'][1]['polygon'].each_with_index.map { |value, index| index.odd? ? value + 1 : value }
    line_span = page['lines'][1]['spans'].sole
    page['words'].select { |word| word['span']['offset'].between?(line_span['offset'], line_span['offset'] + line_span['length'] - 1) }.each do |word|
      word['polygon'] = word['polygon'].each_with_index.map { |value, index| index.odd? ? value + 1 : value }
    end

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end

  it 'item-local税基準とreference lineの税基準が競合する場合は採用しない' do
    expect(extract([ '検証量売品(税込27%)', '税抜 317円/100g', '計量 250g', '明細計 793円' ])).to be_empty
  end

  it 'providerのpartial Itemは明示spanが所属する唯一blockへ関連付ける' do
    response = provider_layout([ '検証商品', '単価 @100円', '数量 2個', '明細計 200円' ])
    total_line = response['pages'].sole['lines'][-2]
    response['documents'].sole['fields']['Items'] = {
      'valueArray' => [
        {
          'spans' => total_line['spans'],
          'valueObject' => {
            'TotalPrice' => {
              'content' => total_line['content'],
              'spans' => total_line['spans'],
              'valueCurrency' => { 'amount' => 200, 'currencyCode' => 'JPY' }
            }
          }
        }
      ]
    }

    descriptors = described_class.call(analyze_result: response, profile:)

    expect(descriptors.sole[:structured_item_indexes]).to eq([ 0 ])
    expect(descriptors.sole[:item_identity]).to start_with('azure_calculation_layout_')
  end

  it 'providerの数値が同一blockのexact sourceと競合した場合は採用しない' do
    response = provider_layout([ '検証商品', '明細計 200円' ])
    total_line = response['pages'].sole['lines'][-2]
    response['documents'].sole['fields']['Items'] = {
      'valueArray' => [
        {
          'spans' => total_line['spans'],
          'valueObject' => {
            'TotalPrice' => {
              'content' => total_line['content'],
              'spans' => total_line['spans'],
              'valueCurrency' => { 'amount' => 201, 'currencyCode' => 'JPY' }
            }
          }
        }
      ]
    }

    expect(described_class.call(analyze_result: response, profile:)).to be_empty
  end
end
