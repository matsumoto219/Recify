require 'rails_helper'

RSpec.describe Ocr::ResponseParser::StoreNameLayoutExtractor do
  let(:texts) { [ 'Sample Store', '中央店 TEL:03-0000-0000', '合計 300' ] }
  let(:analyze_result) do
    offset = 0
    lines = texts.each_with_index.map do |text, index|
      line = {
        'content' => text, 'spans' => [ { 'offset' => offset, 'length' => text.length } ],
        'polygon' => [ 100, 100 + index * 100, 500, 100 + index * 100, 500, 160 + index * 100, 100, 160 + index * 100 ]
      }
      offset += text.length + 1
      line
    end
    {
      'content' => texts.join("\n"), 'stringIndexType' => 'textElements',
      'pages' => [ { 'width' => 1_000, 'height' => 2_000, 'unit' => 'pixel', 'lines' => lines } ]
    }
  end
  let(:fields) do
    { 'MerchantName' => { 'valueString' => 'Sample Store', 'confidence' => 0.87,
                          'spans' => [ { 'offset' => 0, 'length' => 12 } ] } }
  end
  let(:evidence) do
    Ocr::ResponseParser::StoreNameEvidenceExtractor.call(
      analyze_result: analyze_result, fields: fields, lines: texts,
      excluded_line_indexes: [], profile: ReceiptAnalysisProfiles.default
    )
  end

  def extract
    described_class.call(analyze_result: analyze_result, evidence: evidence)
  end

  it 'normalizes only retained candidate lines and preserves the original evidence' do
    original = evidence.deep_dup
    result = extract

    aggregate_failures do
      expect(result).to include(scope: 'provider_line', coordinate_scale: 10_000)
      expect(result[:entries].map { |entry| entry[:candidate_id] }).to contain_exactly('merchant_name', 'page_0_line_0', 'page_0_line_1')
      expect(result[:entries].find { |entry| entry[:candidate_id] == 'page_0_line_0' }).to eq(
        candidate_id: 'page_0_line_0', page_index: 0, provider_line_index: 0,
        line_span: { offset: 0, length: 12 }, bounds: { left: 1_000, top: 500, width: 4_000, height: 300 }
      )
      expect(evidence).to eq(original)
      expect(result.to_json).not_to include('Sample Store', '03-0000-0000', 'polygon', 'content')
    end
  end

  it 'uses the complete source line box for a name trimmed before a phone suffix' do
    result = extract[:entries].find { |entry| entry[:candidate_id] == 'page_0_line_1' }

    aggregate_failures do
      expect(result[:line_span]).to eq(offset: 13, length: texts[1].length)
      expect(result[:bounds]).to eq(left: 1_000, top: 1_000, width: 4_000, height: 300)
      expect(evidence[:candidates].find { |entry| entry[:candidate_id] == 'page_0_line_1' }[:span]).to eq(offset: 13, length: 3)
    end
  end

  it 'does not attach one line box to a merchant field spanning several lines' do
    fields['MerchantName'] = {
      'valueString' => texts.first(2).join("\n"),
      'spans' => [ { 'offset' => 0, 'length' => texts.first(2).join("\n").length } ]
    }

    expect(extract[:entries]).not_to include(include(candidate_id: 'merchant_name'))
  end

  it 'supports exact UTF-16 spans without treating them as character offsets' do
    texts[0] = '店舗名'
    fields.clear
    analyze_result['stringIndexType'] = 'utf16CodeUnit'

    expect(extract[:entries].first[:line_span]).to eq(offset: 0, length: 3)
  end

  { 'utf16CodeUnit' => 5, 'textElements' => 3 }.each do |index_type, length|
    it "maps surrogate and combining boundaries through #{index_type}" do
      normalized = evidence.deep_dup
      candidate = normalized[:candidates].find { |entry| entry[:candidate_id] == 'page_0_line_0' }
      normalized[:candidates] = [ candidate.merge(
        text: "A\u{1F600}é", span: { offset: 0, length: length }, string_index_type: index_type
      ) ]
      content = "A\u{1F600}e\u0301"
      line = analyze_result['pages'][0]['lines'][0]
      line.merge!('content' => content, 'spans' => [ { 'offset' => 0, 'length' => length } ])
      analyze_result['pages'][0]['lines'] = [ line ]
      analyze_result.merge!('content' => content, 'stringIndexType' => index_type)

      result = described_class.call(analyze_result: analyze_result, evidence: normalized)

      expect(result[:entries].first[:line_span]).to eq(offset: 0, length: length)
    end
  end

  it 'preserves the same bounds for either polygon winding direction' do
    expected = extract
    analyze_result['pages'][0]['lines'].each do |line|
      line['polygon'] = line['polygon'].each_slice(2).to_a.reverse.flatten
    end

    expect(extract).to eq(expected)
  end

  it 'omits a box rounded to zero width without inventing a minimum dimension' do
    evidence
    analyze_result['pages'][0]['lines'][0]['polygon'] = [
      100, 100, 100.000001, 100, 100.000001, 160, 100, 160
    ]

    expect(extract[:entries].map { |entry| entry[:candidate_id] }).to eq([ 'page_0_line_1' ])
  end

  it 'preserves page identity when the same position occurs on another page' do
    second_line = analyze_result['pages'][0]['lines'].delete_at(1)
    analyze_result['pages'] << { 'width' => 1_000, 'height' => 2_000, 'lines' => [ second_line ] }

    expect(extract[:entries]).to include(include(candidate_id: 'page_1_line_0', page_index: 1, provider_line_index: 0))
  end

  it 'omits missing geometry without changing extracted name candidates' do
    original = evidence.deep_dup
    analyze_result['pages'][0]['lines'].each { |line| line.delete('polygon') }

    expect(extract).to be_nil
    expect(evidence).to eq(original)
  end

  it 'does not infer layout for legacy evidence without provider pages' do
    analyze_result.delete('pages')

    expect(extract).to be_nil
  end

  it 'rejects unsupported index types without borrowing an earlier mapping' do
    evidence
    analyze_result['stringIndexType'] = 'unknown'

    expect(extract).to be_nil
  end

  it 'rejects a source span that does not exactly identify the provider line' do
    evidence
    analyze_result['pages'][0]['lines'][0]['spans'][0]['offset'] = 1

    expect(extract[:entries].map { |entry| entry[:candidate_id] }).to eq([ 'page_0_line_1' ])
  end

  it 'does not use a candidate span from a different line' do
    normalized = evidence.deep_dup
    normalized[:candidates].each { |candidate| candidate[:span] = { offset: 999, length: 3 } }

    expect(described_class.call(analyze_result: analyze_result, evidence: normalized)).to be_nil
  end

  {
    'missing dimensions' => { 'width' => nil },
    'zero dimensions' => { 'height' => 0 },
    'nonfinite dimensions' => { 'width' => Float::INFINITY },
    'string dimensions' => { 'width' => '1000' }
  }.each do |condition, changes|
    it "omits layout with #{condition}" do
      analyze_result['pages'][0].merge!(changes)

      expect(extract).to be_nil
    end
  end

  {
    'negative coordinates' => [ -1, 100, 500, 100, 500, 160, 100, 160 ],
    'outside page' => [ 100, 100, 1_001, 100, 1_001, 160, 100, 160 ],
    'nonfinite coordinates' => [ Float::NAN, 100, 500, 100, 500, 160, 100, 160 ],
    'self crossing polygon' => [ 100, 100, 500, 160, 500, 100, 100, 160 ],
    'zero area' => [ 100, 100, 500, 100, 500, 100, 100, 100 ],
    'too many points' => [ 100, 100, 500, 100, 500, 160, 100, 160, 100, 100 ]
  }.each do |condition, polygon|
    it "omits only the affected candidate lines for #{condition}" do
      evidence
      analyze_result['pages'][0]['lines'][0]['polygon'] = polygon

      expect(extract[:entries].map { |entry| entry[:candidate_id] }).to eq([ 'page_0_line_1' ])
    end
  end

  it 'rejects oversized pages, line collections and content before traversing them' do
    evidence
    original = analyze_result.deep_dup

    aggregate_failures do
      analyze_result['pages'] = Array.new(101, original['pages'].first)
      expect(extract).to be_nil
      analyze_result.replace(original.deep_dup)
      analyze_result['pages'][0]['lines'] = Array.new(10_001, original['pages'][0]['lines'].first)
      expect(extract).to be_nil
      analyze_result.replace(original.deep_dup)
      analyze_result['content'] = 'x' * 1_048_577
      expect(extract).to be_nil
    end
  end

  it 'omits control-bearing or mismatched line content' do
    evidence
    analyze_result['pages'][0]['lines'][0]['content'] = "Sample\0Store"

    expect(extract[:entries].map { |entry| entry[:candidate_id] }).to eq([ 'page_0_line_1' ])
  end

  it 'adds optional metadata without changing the parser candidates or amount fields' do
    response = {
      'analyzeResult' => analyze_result.merge(
        'documents' => [ { 'docType' => 'receipt', 'fields' => fields.merge(
          'Total' => { 'valueCurrency' => { 'amount' => 300, 'currencyCode' => 'JPY' } },
          'CountryRegion' => { 'valueCountryRegion' => 'JPN' }
        ) } ]
      )
    }
    with_layout = Ocr::ResponseParser.new(response: response, provider: 'azure').call
    response['analyzeResult']['pages'][0]['lines'].each { |line| line.delete('polygon') }
    without_layout = Ocr::ResponseParser.new(response: response, provider: 'azure').call

    aggregate_failures do
      expect(with_layout[:success]).to be(true)
      expect(with_layout.dig(:meta, :store_name_layout)).to include(scope: 'provider_line')
      expect(without_layout[:meta]).not_to have_key(:store_name_layout)
      expect(with_layout.except(:meta)).to eq(without_layout.except(:meta))
      expect(with_layout.dig(:candidates, :total_amount)).to eq(300)
    end
  end
end
