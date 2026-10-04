require 'rails_helper'

RSpec.describe Ocr::ResponseParser::StoreNameEvidenceExtractor do
  let(:texts) { [ 'Sample Store', '中央店', '合計 300', '運営会社', '架空販売株式会社' ] }
  let(:analyze_result) do
    offset = 0
    lines = texts.map do |text|
      line = { 'content' => text, 'spans' => [ { 'offset' => offset, 'length' => text.length } ] }
      offset += text.length + 1
      line
    end
    {
      'content' => texts.join("\n"), 'stringIndexType' => 'textElements',
      'pages' => [ { 'lines' => lines } ]
    }
  end
  let(:fields) do
    { 'MerchantName' => { 'valueString' => 'Sample Store', 'confidence' => 0.87,
                          'spans' => [ { 'offset' => 0, 'length' => 12 } ] } }
  end

  def extract(**options)
    described_class.call(
      analyze_result: analyze_result, fields: fields, lines: texts,
      excluded_line_indexes: [], profile: ReceiptAnalysisProfiles.default, **options
    )
  end

  it 'retains atomic field and line candidates with source-owned confidence and exact spans' do
    result = extract
    merchant = result[:candidates].find { |candidate| candidate[:source] == 'merchant_name' }
    branch = result[:candidates].find { |candidate| candidate[:text] == '中央店' }

    aggregate_failures do
      expect(result).to include(invalid: false, truncated: false)
      expect(merchant).to include(candidate_id: 'merchant_name', confidence: 0.87, span_state: 'exact', line_index: 0)
      expect(branch).to include(candidate_id: 'page_0_line_1', source_path: 'pages[0].lines[1]', line_index: 1)
      expect(branch).not_to have_key(:confidence)
      expect(result[:candidates].map { |candidate| candidate[:text] }).not_to include('Sample Store 中央店')
    end
  end

  it 'keeps provider identity separate from normalized line indexes when blank lines occur' do
    analyze_result['pages'][0]['lines'].unshift('content' => '  ')
    result = extract
    line = result[:candidates].find { |candidate| candidate[:source] == 'line' && candidate[:text] == 'Sample Store' }

    expect(line).to include(candidate_id: 'page_0_line_1', provider_line_index: 1, line_index: 0)
  end

  it 'does not borrow MerchantName confidence for line candidates or infer absent spans' do
    fields['MerchantName'].delete('spans')
    analyze_result['pages'][0]['lines'][0].delete('spans')
    result = extract

    aggregate_failures do
      expect(result[:candidates].first).to include(confidence: 0.87, span_state: 'missing')
      expect(result[:candidates].select { |candidate| candidate[:source] == 'line' }).not_to include(have_key(:confidence))
      expect(result[:candidates].first).not_to have_key(:span)
    end
  end

  it 'preserves contradictory spans as invalid instead of claiming a safe missing source' do
    fields['MerchantName']['spans'][0]['offset'] = 1

    expect(extract[:candidates].first).to include(span_state: 'invalid')
  end

  it 'retains footer store evidence and does not clip it to the initial header' do
    texts.replace([ '領収書' ] + Array.new(12, '300') + [ 'Example Footer Store' ])
    fields.clear

    expect(extract[:candidates]).to include(include(text: 'Example Footer Store', line_index: 13))
  end

  it 'retains the exact MerchantName source block even when payment notes follow the footer' do
    texts.replace([ 'Sample Store' ] + Array.new(12, '300') + [ 'Sample Store Area', '中町給油所' ] + Array.new(12, '400'))
    fields['MerchantName']['spans'][0]['offset'] = texts.first(13).sum { |text| text.length + 1 }

    expect(extract[:candidates]).to include(
      include(text: 'Sample Store Area', line_index: 13, span_state: 'exact'),
      include(text: '中町給油所', line_index: 14, span_state: 'exact')
    )
  end

  it 'does not extend the MerchantName source block across a page boundary' do
    texts.replace([ 'Sample Store' ] + Array.new(12, '300') + [ 'Sample Store Area', '中町給油所' ] + Array.new(12, '400'))
    fields['MerchantName']['spans'][0]['offset'] = texts.first(13).sum { |text| text.length + 1 }
    original_lines = analyze_result['pages'][0]['lines']
    analyze_result['pages'] = [ { 'lines' => original_lines.first(14) }, { 'lines' => original_lines.drop(14) } ]

    expect(extract[:candidates]).not_to include(include(text: '中町給油所'))
  end

  it 'does not extend an invalid MerchantName span into unrelated source lines' do
    texts.replace([ 'Sample Store' ] + Array.new(12, '300') + [ 'Sample Store Area', '中町給油所' ] + Array.new(12, '400'))
    fields['MerchantName']['spans'][0]['offset'] = texts.first(13).sum { |text| text.length + 1 } + 1

    expect(extract[:candidates]).not_to include(include(text: '中町給油所'))
  end

  it 'does not apply brand-only geographic exclusions to a branch line' do
    texts[1] = '架空市北町店'

    expect(extract[:candidates]).to include(include(text: '架空市北町店', line_index: 1))
  end

  it 'retains a branch before a phone suffix with the exact name component span only' do
    texts[1] = '中央店 TEL:03-0000-0000'
    branch = extract[:candidates].find { |candidate| candidate[:line_index] == 1 }

    aggregate_failures do
      expect(branch).to include(text: '中央店', source_path: 'pages[0].lines[1]', span_state: 'exact')
      expect(branch[:span]).to eq(offset: 13, length: 3)
      expect(extract.to_json).not_to include('03-0000-0000')
    end
  end

  it 'does not invent a name component span when a full-width phone suffix cannot be located exactly' do
    texts[1] = '中央店 ＴＥＬ：０３－００００－００００'

    expect(extract[:candidates]).to include(include(text: '中央店', span_state: 'missing'))
  end

  it 'retains a contradictory span as invalid when removing the phone suffix' do
    texts[1] = '中央店 TEL:03-0000-0000'
    analyze_result['pages'][0]['lines'][1]['spans'][0]['offset'] = 0

    expect(extract[:candidates]).to include(include(text: '中央店', span_state: 'invalid'))
  end

  it 'does not duplicate a phone suffix from MerchantName into the new evidence' do
    texts[0] = 'Sample Store TEL:03-0000-0000'
    fields['MerchantName']['valueString'] = texts[0]
    fields['MerchantName']['spans'][0]['length'] = texts[0].length

    aggregate_failures do
      expect(extract[:candidates].first).to include(text: 'Sample Store', source: 'merchant_name', confidence: 0.87)
      expect(extract[:candidates].first[:span]).to eq(offset: 0, length: 12)
      expect(extract.to_json).not_to include('03-0000-0000')
    end
  end

  it 'does not retain a phone-only MerchantName as a store name' do
    fields['MerchantName'] = { 'valueString' => 'TEL:03-0000-0000', 'confidence' => 0.99 }

    expect(extract[:candidates]).not_to include(include(source: 'merchant_name'))
  end

  it 'uses the same limited phone suffix normalization for legacy fallback lines' do
    texts[1] = '中央店 TEL:03-0000-0000'
    analyze_result.clear

    expect(extract[:candidates]).to include(include(text: '中央店', source_path: 'lines[1]', span_state: 'missing'))
  end

  it 'excludes already validated calculation block lines without renumbering the remaining source' do
    result = extract(excluded_line_indexes: [ 0, 1 ])

    aggregate_failures do
      expect(result[:candidates]).not_to include(include(text: 'Sample Store'))
      expect(result[:candidates]).not_to include(include(text: '中央店'))
      expect(result[:candidates]).to include(include(text: '架空販売株式会社', line_index: 4))
    end
  end

  it 'uses the injected profile to exclude receipt-specific noise' do
    profile = ReceiptAnalysisProfiles.default.dup
    allow(profile).to receive(:ocr_store_name_noise_pattern).and_return(/Sample Store/)
    fields.clear

    expect(extract(profile: profile)[:candidates]).not_to include(include(text: 'Sample Store'))
  end

  it 'marks candidate clipping and malformed provider line collections explicitly' do
    aggregate_failures do
      expect(extract(max_candidates: 1)).to include(truncated: true)
      analyze_result['pages'][0]['lines'] = 'bad'
      expect(extract).to include(invalid: true)
    end
  end

  it 'does not spend the candidate budget on known receipt context and greeting lines' do
    texts.replace([
      'Sample Store', '中央店', '東京都千代田区1-2-3', '2026/01/01 12:34', '登録番号 T1234567890123',
      '担当 01', 'No.000123', '消費税 10', '現金 300', 'ありがとうございました'
    ])
    result = extract(max_candidates: 3)

    aggregate_failures do
      expect(result[:truncated]).to be(false)
      expect(result[:candidates].map { |candidate| candidate[:text] }).to eq([ 'Sample Store', 'Sample Store', '中央店' ])
    end
  end

  it 'does not treat an unsupported provider index type as a missing span' do
    analyze_result['stringIndexType'] = 'unicodeCodePoint'

    expect(extract[:candidates].first).to include(span_state: 'invalid')
  end

  it 'does not discard a store name just because it contains a payment term' do
    texts[1] = '現金問屋 中央店'

    expect(extract[:candidates]).to include(include(text: '現金問屋 中央店'))
  end

  it 'distinguishes missing legacy index metadata from contradictory span values' do
    analyze_result.delete('stringIndexType')

    aggregate_failures do
      expect(extract[:candidates].first).to include(span_state: 'missing')
      fields['MerchantName']['spans'][0]['offset'] = -1
      expect(extract[:candidates].first).to include(span_state: 'invalid')
    end
  end

  it 'does not turn a large line into a shortened candidate' do
    texts[0] = 'a' * 501
    fields.clear

    expect(extract[:candidates]).not_to include(include(text: 'a' * 500))
  end

  it 'supports fallback OCR lines without inventing Azure page or span evidence' do
    analyze_result.clear
    fields.clear

    candidate = extract[:candidates].first
    aggregate_failures do
      expect(candidate).to include(candidate_id: 'line_0', source_path: 'lines[0]', line_index: 0, span_state: 'missing')
      expect(candidate).not_to have_key(:page_index)
      expect(candidate).not_to have_key(:span)
    end
  end

  it 'bounds total line bytes before normalizing an oversized source' do
    analyze_result['pages'][0]['lines'] = Array.new(3) { { 'content' => 'a' * 400_000 } }

    expect(extract).to include(invalid: true, candidates: [])
  end

  it 'accepts ASCII binary strings without changing their source text or raising' do
    analyze_result['pages'][0]['lines'][0]['content'] = 'Sample Store'.b

    expect(extract[:candidates]).to include(include(source: 'line', text: 'Sample Store'))
  end

  it 'rejects invalid text encoding without returning provider content in an error' do
    analyze_result['pages'][0]['lines'][0]['content'] = "\xff".force_encoding(Encoding::UTF_8)

    expect(extract).to include(invalid: true, candidates: [])
  end
end
