require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  def calculation_fallback_response(structured: nil)
    offset = 0
    words = []
    text_lines = [ 'レシート', '検証商品', '単価 @100円', '数量 2個', '明細計 200円', '合計 200円' ]
    lines = text_lines.map.with_index do |text, index|
      top = 20 + index * 24
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
        'polygon' => [ 20, top, 20 + text.length * 10, top, 20 + text.length * 10, top + 16, 20, top + 16 ]
      }
      offset += text.length + 1
      line
    end
    fields = {}
    if structured
      children = {
        'Description' => {
          'valueString' => text_lines[1],
          'content' => text_lines[1],
          'spans' => lines[1]['spans'].deep_dup
        },
        'TotalPrice' => calculation_fallback_currency_field(200, '200円', lines[4]['spans'].sole['offset'] + 4)
      }
      if structured == :complete
        children['Price'] = calculation_fallback_currency_field(100, '@100円', lines[2]['spans'].sole['offset'] + 3)
        children['Quantity'] = {
          'valueNumber' => 2,
          'content' => '2',
          'spans' => [ { 'offset' => lines[3]['spans'].sole['offset'] + 3, 'length' => 1 } ]
        }
        children['QuantityUnit'] = {
          'valueString' => '個',
          'content' => '個',
          'spans' => [ { 'offset' => lines[3]['spans'].sole['offset'] + 4, 'length' => 1 } ]
        }
      end
      item_content = text_lines[1..4].join("\n")
      fields['Items'] = {
        'valueArray' => [
          {
            'content' => item_content,
            'spans' => [ { 'offset' => lines[1]['spans'].sole['offset'], 'length' => item_content.length } ],
            'valueObject' => children
          }
        ]
      }
    end

    {
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => 'textElements',
        'content' => text_lines.join("\n"),
        'pages' => [
          {
            'pageNumber' => 1,
            'unit' => 'pixel',
            'width' => 600,
            'height' => 200,
            'lines' => lines,
            'words' => words
          }
        ],
        'documents' => [ { 'fields' => fields } ]
      }
    }
  end

  def calculation_fallback_currency_field(amount, content, offset)
    {
      'valueCurrency' => { 'amount' => amount, 'currencyCode' => 'JPY' },
      'content' => content,
      'spans' => [ { 'offset' => offset, 'length' => content.length } ]
    }
  end

  it 'keeps the complete structured count path instead of replacing its source identity' do
    result = described_class.new(response: calculation_fallback_response(structured: :complete)).call
    candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole

    expect(candidate[:source_provider]).to eq('azure_structured')
    expect(candidate[:options].map { |option| option[:pricing_source_kind] }).to eq(%w[count_unit_price explicit_line_total])
    expect(result.dig(:candidates, :items).sole[:ocr_item_identity]).to eq(candidate[:item_identity])
  end

  it 'replaces an incomplete structured fragment only with a complete same-block layout item' do
    result = described_class.new(response: calculation_fallback_response(structured: :incomplete)).call
    candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole

    expect(candidate[:source_provider]).to eq('azure_calculation_layout')
    expect(candidate[:source_field_path]).to eq('pages[0].lines[1]')
    expect(candidate[:options].map { |option| option[:pricing_source_kind] }).to eq(%w[count_unit_price explicit_line_total])
    expect(result.dig(:candidates, :items).sole).to include(raw_text: '検証商品', price: 100, quantity: '2', line_total: 200, original_line_total: 200)
    expect(result.dig(:candidates, :reference_pricing_candidates)).to eq([])
  end

  it 'strips runtime word evidence only after checking the actual page, line and word ownership' do
    result = described_class.new(response: calculation_fallback_response).call
    candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole
    components = [ candidate[:destination_evidence], candidate.dig(:printed_line_total, :evidence) ] +
      candidate[:options].flat_map { |option| option[:evidence].values }

    expect(components.map(&:keys)).to all(match_array(%i[source_field_path provider_span_start provider_span_end]))
    expect(result.dig(:candidates, :reference_pricing_block_line_indexes)).to eq([ 1, 2, 3, 4 ])
    expect(result.dig(:candidates, :total_amount)).to eq(200)
    expect(result.dig(:candidates, :adjustment_candidates)).to be_empty
  end

  it 'fails neutral on foreign, incomplete or altered runtime component evidence' do
    mutations = [
      ->(evidence) { evidence[:page_index] = 1 },
      ->(evidence) { evidence[:source_field_path] = 'documents[0].fields.Items[0].Price' },
      ->(evidence) { evidence[:word_spans] = [] },
      ->(evidence) { evidence[:word_spans].first[:provider_span_start] += 1 },
      ->(evidence) { evidence[:provider_span_start] = 0 }
    ]

    mutations.each do |mutation|
      allow(Ocr::ResponseParser::ItemCalculationModeLayoutExtractor).to receive(:call).and_wrap_original do |method, **arguments|
        descriptors = method.call(**arguments)
        mutation.call(descriptors.sole[:options].first[:evidence][:price])
        descriptors
      end
      result = described_class.new(response: calculation_fallback_response).call

      expect(result[:success]).to be(true)
      expect(result.dig(:candidates, :item_calculation_mode_candidates)).to eq([])
      expect(result.dig(:candidates, :items)).to eq([])
    end
  end
end
