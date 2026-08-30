require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  def discount_response(
    discontiguous: false,
    split: false,
    item_count: 1,
    price: 50,
    rate: 27,
    amount: 14,
    discount_line: nil,
    name_prefix: '検証品',
    string_index_type: 'textElements',
    fullwidth: false
  )
    content = +''
    lines = []
    printed = ->(value) { fullwidth ? value.tr('0-9.@%-', '０-９．＠％－') : value }
    items = Array.new(item_count) do |index|
      name = "#{name_prefix}#{index + 1}(税込#{index + 1}%)"
      discount_amount = amount - index
      discount_rate = rate - index
      total = price - discount_amount
      item_lines = [ name, "単価 @#{price}円", '数量 1個' ]
      item_lines.concat(split ? [ '明細値引', "#{discount_rate}%", "-#{discount_amount}円" ] : [ discount_line || "明細値引 #{discount_rate}% -#{discount_amount}円" ])
      item_lines << "明細計 #{total}円"
      item_lines.map!(&printed)
      name = item_lines.first
      item_start = discount_length(content, string_index_type)
      source_lines = item_lines.map do |line|
        value = { 'content' => line, 'spans' => [ { 'offset' => discount_length(content, string_index_type), 'length' => discount_length(line, string_index_type) } ] }
        content << "#{line}\n"
        lines << value
        value
      end
      total_offset = source_lines.last.dig('spans', 0, 'offset') + '明細計 '.length
      parent_spans = if discontiguous
        [
          { 'offset' => item_start, 'length' => source_lines.last.dig('spans', 0, 'offset') - item_start - 1 },
          { 'offset' => total_offset, 'length' => "#{total}円".length }
        ]
      else
        [ { 'offset' => item_start, 'length' => discount_length(content, string_index_type) - item_start - 1 } ]
      end

      {
        'content' => item_lines.join("\n"),
        'spans' => parent_spans,
        'valueObject' => {
          'Description' => { 'valueString' => name, **source_lines.first },
          'Price' => discount_currency_field(printed.call("@#{price}円"), price, source_lines[1].dig('spans', 0, 'offset') + '単価 '.length),
          'Quantity' => {
            'valueNumber' => 1,
            'content' => printed.call('1'),
            'spans' => [ { 'offset' => source_lines[2].dig('spans', 0, 'offset') + '数量 '.length, 'length' => 1 } ]
          },
          'QuantityUnit' => {
            'valueString' => '個',
            'content' => '個',
            'spans' => [ { 'offset' => source_lines[2].dig('spans', 0, 'offset') + '数量 1'.length, 'length' => 1 } ]
          },
          'TotalPrice' => discount_currency_field(printed.call("#{total}円"), total, total_offset)
        }
      }
    end
    receipt_total = item_count.times.sum { |index| price - amount + index }
    summary = "合計 #{receipt_total}円"
    lines << { 'content' => summary, 'spans' => [ { 'offset' => discount_length(content, string_index_type), 'length' => summary.length } ] }
    content << summary

    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => string_index_type,
        'content' => content,
        'pages' => [ { 'pageNumber' => 1, 'lines' => lines } ],
        'documents' => [
          {
            'fields' => {
              'CountryRegion' => { 'valueCountryRegion' => 'JPN' },
              'Total' => { 'valueNumber' => receipt_total },
              'Items' => { 'valueArray' => items }
            }
          }
        ]
      }
    }
  end

  def discount_length(value, index_type)
    Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: index_type).length(value)
  end

  def discount_currency_field(content, amount, offset)
    {
      'content' => content,
      'valueCurrency' => { 'amount' => amount, 'currencyCode' => 'JPY' },
      'spans' => [ { 'offset' => offset, 'length' => content.length } ]
    }
  end

  it '同一明細の率と符号付き割引額を別々に保持し割引後合計を再減算しない' do
    result = described_class.new(response: discount_response).call

    expect(result.dig(:candidates, :items).sole).to include(
      original_line_total: 50, discount_rate: BigDecimal('0.27'), discount_amount: 14, line_total: 36, tax_rate: BigDecimal('0.01')
    )
  end

  it '同一明細の割引率と金額のexact spanをcount optionへ渡す' do
    [ [ 1, 1 ], [ 27, 14 ], [ 59, 30 ], [ 99, 50 ] ].each do |rate, amount|
      response = discount_response(rate:, amount:)
      result = described_class.new(response: response).call
      candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole
      option = candidate[:options].find { |entry| entry[:pricing_source_kind] == 'count_unit_price' }

      expect(option).not_to be_nil
      expect(candidate[:conflicts]).to eq([ 'discount' ])
      expect(option[:discount]).to include(amount: amount.to_s, rate: (BigDecimal(rate) / 100).to_s('F'), printed_total_stage: 'after_item_discount')
      option[:discount][:evidence].each do |key, evidence|
        expect(evidence[:source_field_path]).to eq('documents[0].fields.Items[0]')
        span = evidence[:provider_span_start]...evidence[:provider_span_end]
        expect(response.dig('analyzeResult', 'content')[span]).to eq((key == :rate ? rate : amount).to_s)
      end
    end
  end

  it '正の率から丸めた印字0円割引をmissingへ変換しない' do
    result = described_class.new(response: discount_response(price: 1, rate: 1, amount: 0)).call

    expect(result.dig(:candidates, :items).sole).to include(
      original_line_total: 1, line_total: 1, discount_amount: 0, discount_rate: BigDecimal('0.01')
    )
    option = result.dig(:candidates, :item_calculation_mode_candidates).sole[:options].find { |entry| entry[:pricing_source_kind] == 'count_unit_price' }
    expect(option).to include(discount: include(amount: '0', rate: '0.01'))
  end

  it '割引率または割引額の欠損と対象外の率ではcount割引proofを作らない' do
    [
      '明細値引 27%',
      '明細値引 -14円',
      '明細値引 0% -0円',
      '明細値引 100% -50円',
      '明細値引 27% 27% -14円',
      '明細値引 27.01% -14円',
      '明細値引 27% -14USD',
      '明細値引 27% -14円/L',
      '明細値引 27% -14.5円'
    ].each do |discount_line|
      result = described_class.new(response: discount_response(discount_line:)).call

      expect(result.dig(:candidates, :item_calculation_mode_candidates).sole[:options].map { |option| option[:pricing_source_kind] }).to eq([ 'explicit_line_total' ])
    end
  end

  it '同一行割引の検証に注入profileを使用し以前の固定語彙へ戻らない' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_item_calculation_discount_line_pattern)
      .and_return(/\A明細値引 (?<rate>\d+)% -(?<amount>\d+)円 ONLY\z/)

    modes = [ '明細値引 27% -14円 ONLY', '明細値引 27% -14円' ].map do |discount_line|
      result = described_class.new(response: discount_response(discount_line:), profile:).call
      result.dig(:candidates, :item_calculation_mode_candidates).sole[:options].map { |option| option[:pricing_source_kind] }
    end

    expect(modes).to eq([ %w[count_unit_price explicit_line_total], [ 'explicit_line_total' ] ])
  end

  it 'Unicodeを含む明細でも両index typeで割引captureのraw位置を保持する' do
    %w[utf16CodeUnit textElements].each do |string_index_type|
      response = discount_response(name_prefix: "Cafe\u0301😀", string_index_type:, fullwidth: true)
      result = described_class.new(response: response).call
      option = result.dig(:candidates, :item_calculation_mode_candidates).sole[:options].find { |entry| entry[:pricing_source_kind] == 'count_unit_price' }

      expect(option).not_to be_nil
      mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: string_index_type)
      option[:discount][:evidence].each do |key, evidence|
        expect(mapper.slice(response.dig('analyzeResult', 'content'), offset: evidence[:provider_span_start], length: evidence[:provider_span_end] - evidence[:provider_span_start])).to eq(key == :rate ? '２７' : '１４')
      end
    end
  end

  it '非連続parent spanでも明細合計componentの完全包含で割引後を確認する' do
    result = described_class.new(response: discount_response(discontiguous: true)).call

    expect(result.dig(:candidates, :items).sole).to include(
      original_line_total: 50, discount_rate: BigDecimal('0.27'), discount_amount: 14, line_total: 36
    )
  end

  it '割引ラベル・率・金額の分離行を同一明細へ対応させる' do
    result = described_class.new(response: discount_response(split: true)).call

    expect(result.dig(:candidates, :items).sole).to include(
      original_line_total: 50, discount_rate: BigDecimal('0.27'), discount_amount: 14, line_total: 36, tax_rate: BigDecimal('0.01')
    )
  end

  it '次の購入明細の税率や割引額を前の明細へ関連付けない' do
    result = described_class.new(response: discount_response(item_count: 2)).call

    expect(result.dig(:candidates, :items)).to match([
      include(original_line_total: 50, discount_rate: BigDecimal('0.27'), discount_amount: 14, line_total: 36, tax_rate: BigDecimal('0.01')),
      include(original_line_total: 50, discount_rate: BigDecimal('0.26'), discount_amount: 13, line_total: 37, tax_rate: BigDecimal('0.02'))
    ])
  end

  it 'unsupported index typeでは割引後と推測してTotalPriceへ再割引しない' do
    response = discount_response
    response['analyzeResult']['stringIndexType'] = 'unknown'

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).sole).to include(line_total: 36, discount_amount: nil, discount_rate: nil)
  end

  it '明細合計componentがparent外なら割引後sourceを作らない' do
    response = discount_response
    item = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray').sole
    item['spans'].sole['length'] = item.dig('valueObject', 'TotalPrice', 'spans', 0, 'offset') - 1

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).sole).to include(line_total: 36, discount_amount: nil, discount_rate: nil)
  end

  it '重複する別Itemが同じ割引と合計spanを所有する場合は割引後sourceを作らない' do
    response = discount_response
    items = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray')
    items << items.sole.deep_dup

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items)).to all(include(line_total: 36, discount_amount: nil, discount_rate: nil))
  end

  it 'page layoutが欠損しても割引後の印字合計から再減算しない' do
    response = discount_response
    response['analyzeResult'].delete('pages')

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).sole).to include(line_total: 36, discount_amount: nil, discount_rate: nil)
  end

  it '割引と明細合計の間に別行があれば割引後sourceを推測しない' do
    response = discount_response
    response.dig('analyzeResult', 'pages', 0, 'lines').insert(4, { 'content' => '注記' })

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).sole).to include(line_total: 36, discount_amount: nil, discount_rate: nil)
  end

  it '単位あたりの値引き説明を明細全体の割引額へ昇格しない' do
    response = discount_response
    line = response.dig('analyzeResult', 'pages', 0, 'lines')[3]
    line['content'] = '明細値引 -14円/L'
    response['analyzeResult']['content'].sub!('明細値引 27% -14円', line['content'])
    response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray').sole['content'].sub!('明細値引 27% -14円', line['content'])
    response['analyzeResult'].delete('pages')

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).sole).to include(line_total: 36, discount_amount: nil, discount_rate: nil)
  end

  it '明細合計spanが合計欄へ改変されていたら割引後sourceを作らない' do
    response = discount_response
    item = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray').sole
    summary = response.dig('analyzeResult', 'pages', 0, 'lines').last
    item['valueObject']['TotalPrice'] = discount_currency_field('36円', 36, summary.dig('spans', 0, 'offset') + '合計 '.length)

    result = described_class.new(response: response).call

    expect(result.dig(:candidates, :items).sole).to include(line_total: 36, discount_amount: nil, discount_rate: nil)
  end
end
