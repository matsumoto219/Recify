require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  def description_response(description: '例示市商品券', prefix: '001 ', suffix: ' 900', index_type: 'textElements')
    provider_length = lambda do |text|
      index_type == 'utf16CodeUnit' ? text.encode('UTF-16LE').bytesize / 2 : text.scan(/\X/).size
    end
    line = "#{prefix}#{description}#{suffix}"
    region = [ { 'pageNumber' => 1 } ]
    span = { 'offset' => 0, 'length' => provider_length.call(line) }
    description_span = { 'offset' => provider_length.call(prefix), 'length' => provider_length.call(description) }
    {
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt', 'apiVersion' => '2024-11-30', 'stringIndexType' => index_type,
        'content' => line,
        'pages' => [ { 'pageNumber' => 1, 'lines' => [ { 'content' => line, 'spans' => [ span.deep_dup ] } ] } ],
        'documents' => [
          {
            'fields' => {
              'Items' => {
                'valueArray' => [
                  {
                    'content' => line, 'spans' => [ span.deep_dup ], 'boundingRegions' => region.deep_dup,
                    'valueObject' => {
                      'Description' => { 'content' => description, 'valueString' => description, 'spans' => [ description_span ], 'boundingRegions' => region.deep_dup },
                      'TotalPrice' => { 'valueCurrency' => { 'amount' => 900 } }
                    }
                  }
                ]
              }
            }
          }
        ]
      }
    }
  end

  def description_items(response)
    described_class.new(response: response, provider: 'azure').call.dig(:candidates, :items)
  end

  it '部分行のDescriptionだけを同じItem parentとprovider spanから関連付ける' do
    result = described_class.new(response: description_response, provider: 'azure').call

    aggregate_failures do
      expect(result.dig(:candidates, :items, 0)).to include(
        raw_text: '例示市商品券', line_total: 900,
        description_source_refs: [ { line_index: 0, character_offset: 4, character_length: 6 } ]
      )
      expect(result[:lines]).to eq([ '001 例示市商品券 900' ])
    end
  end

  %w[textElements utf16CodeUnit].each do |index_type|
    it "#{index_type}のUnicode境界を正規化行のcode point位置へ変換する" do
      response = description_response(description: '例示市Ａ券', prefix: "😀e\u0301  ", index_type: index_type)

      expect(description_items(response).first[:description_source_refs]).to eq(
        [ { line_index: 0, character_offset: 3, character_length: 5 } ]
      )
    end
  end

  it '複数行Descriptionの各componentを同じpage内の一意な行へ結び付ける' do
    response = description_response
    data = response.fetch('analyzeResult')
    data['content'] = "001 例示市\n商品券 900"
    data['pages'].first['lines'] = [
      { 'content' => '001 例示市', 'spans' => [ { 'offset' => 0, 'length' => 7 } ] },
      { 'content' => '商品券 900', 'spans' => [ { 'offset' => 8, 'length' => 7 } ] }
    ]
    item = data.dig('documents', 0, 'fields', 'Items', 'valueArray', 0)
    item['content'] = data['content']
    item['spans'] = [ { 'offset' => 0, 'length' => 15 } ]
    item['valueObject']['Description'].merge!(
      'content' => "例示市\n商品券", 'valueString' => "例示市\n商品券",
      'spans' => [ { 'offset' => 4, 'length' => 3 }, { 'offset' => 8, 'length' => 3 } ]
    )

    expect(description_items(response).first[:description_source_refs]).to eq([
      { line_index: 0, character_offset: 4, character_length: 3 },
      { line_index: 1, character_offset: 0, character_length: 3 }
    ])
  end

  {
    'unsupported index type' => ->(data, _item) { data['stringIndexType'] = 'unicodeCodePoint' },
    'unknown model' => ->(data, _item) { data['modelId'] = 'other' },
    'unknown API' => ->(data, _item) { data['apiVersion'] = 'unknown' },
    'missing Description span' => ->(_data, item) { item['valueObject']['Description'].delete('spans') },
    'partial Description span' => ->(_data, item) { item['valueObject']['Description']['spans'].first['length'] -= 1 },
    'different Description value' => ->(_data, item) { item['valueObject']['Description']['valueString'] = '別の検証品' },
    'out-of-parent Description' => ->(_data, item) { item['spans'].first['length'] -= 4 },
    'negative span' => ->(_data, item) { item['valueObject']['Description']['spans'].first['offset'] = -1 },
    'oversized span' => ->(_data, item) { item['valueObject']['Description']['spans'].first['length'] = 100_000_000 },
    'another Description page' => ->(_data, item) { item['valueObject']['Description']['boundingRegions'].first['pageNumber'] = 2 },
    'unknown parent page' => ->(_data, item) { item.delete('boundingRegions') },
    'too many Description spans' => ->(_data, item) { item['valueObject']['Description']['spans'] *= 17 },
    'duplicate provider line' => ->(data, _item) { data['pages'].first['lines'] *= 2 },
    'overlapping Item parents' => ->(data, item) { data['documents'].first['fields']['Items']['valueArray'] << item.deep_dup },
    'too many pages' => ->(data, _item) { data['pages'] *= 9 },
    'too many proof lines' => ->(data, _item) { data['pages'].first['lines'] *= 151 }
  }.each do |name, mutation|
    it "#{name}では商品データを保持してDescription proofだけを作らない" do
      response = description_response
      data = response.fetch('analyzeResult')
      item = data.dig('documents', 0, 'fields', 'Items', 'valueArray', 0)
      mutation.call(data, item)
      result = description_items(response)

      aggregate_failures do
        expect(result).not_to be_empty
        expect(result).to all(include(line_total: 900))
        expect(result).to all(satisfy { |entry| !entry.key?(:description_source_refs) })
      end
    end
  end

  it '同じ文字列の別行を検索してDescription所有権を移さない' do
    response = description_response
    data = response.fetch('analyzeResult')
    data['pages'].first['lines'].first['spans'].first['offset'] = 1

    expect(description_items(response).first).not_to have_key(:description_source_refs)
  end

  it 'Unicode正規化がDescription境界を跨ぐ場合は位置を推測しない' do
    response = description_response(description: "\u0301券", prefix: 'e', index_type: 'utf16CodeUnit')

    expect(description_items(response).first).not_to have_key(:description_source_refs)
  end
end
