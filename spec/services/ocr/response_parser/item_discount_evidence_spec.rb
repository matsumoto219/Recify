require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  def discount_response(discontiguous: false, split: false, item_count: 1)
    content = +''
    lines = []
    items = Array.new(item_count) do |index|
      name = "検証品#{index + 1}(税込#{index + 1}%)"
      discount_amount = 14 - index
      discount_rate = 27 - index
      total = 50 - discount_amount
      item_lines = [ name, '単価 @50円', '数量 1個' ]
      item_lines.concat(split ? [ '明細値引', "#{discount_rate}%", "-#{discount_amount}円" ] : [ "明細値引 #{discount_rate}% -#{discount_amount}円" ])
      item_lines << "明細計 #{total}円"
      item_start = content.length
      source_lines = item_lines.map do |line|
        value = { 'content' => line, 'spans' => [ { 'offset' => content.length, 'length' => line.length } ] }
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
        [ { 'offset' => item_start, 'length' => content.length - item_start - 1 } ]
      end

      {
        'content' => item_lines.join("\n"),
        'spans' => parent_spans,
        'valueObject' => {
          'Description' => { 'valueString' => name, **source_lines.first },
          'Price' => discount_currency_field('@50円', 50, source_lines[1].dig('spans', 0, 'offset') + '単価 '.length),
          'Quantity' => {
            'valueNumber' => 1,
            'content' => '1',
            'spans' => [ { 'offset' => source_lines[2].dig('spans', 0, 'offset') + '数量 '.length, 'length' => 1 } ]
          },
          'QuantityUnit' => {
            'valueString' => '個',
            'content' => '個',
            'spans' => [ { 'offset' => source_lines[2].dig('spans', 0, 'offset') + '数量 1'.length, 'length' => 1 } ]
          },
          'TotalPrice' => discount_currency_field("#{total}円", total, total_offset)
        }
      }
    end
    receipt_total = item_count.times.sum { |index| 36 + index }
    summary = "合計 #{receipt_total}円"
    lines << { 'content' => summary, 'spans' => [ { 'offset' => content.length, 'length' => summary.length } ] }
    content << summary

    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => 'textElements',
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
