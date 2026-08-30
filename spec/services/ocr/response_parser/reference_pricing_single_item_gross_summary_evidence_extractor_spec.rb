require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor do
  def analyze_result(
    line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '(内税額 ¥54)',
      '合計 ¥600'
    ],
    line_layout: {},
    string_index_type: 'textElements',
    model_id: 'prebuilt-receipt',
    api_version: '2024-11-30'
  )
    content = line_contents.join("\n")
    offset = 0
    lines = line_contents.map.with_index do |line_content, line_index|
      length = provider_length(line_content, string_index_type)
      layout = line_layout.fetch(line_index, {})
      left = layout.fetch(:left, 20)
      top = layout.fetch(:top, 20 + (line_index * 24))
      width = layout.fetch(:width, 120)
      height = layout.fetch(:height, 16)
      line = {
        'content' => line_content,
        'polygon' => [ left, top, left + width, top, left + width, top + height, left, top + height ],
        'spans' => [ { 'offset' => offset, 'length' => length } ]
      }
      offset += length + provider_length("\n", string_index_type)
      line
    end

    {
      'modelId' => model_id,
      'apiVersion' => api_version,
      'stringIndexType' => string_index_type,
      'content' => content,
      'pages' => [
        {
          'pageNumber' => 1,
          'unit' => 'pixel',
          'width' => 800,
          'height' => 1_200,
          'lines' => lines
        }
      ]
    }
  end

  def provider_length(value, string_index_type)
    if string_index_type == 'utf16CodeUnit'
      value.each_char.sum { |character| character.ord > 0xFFFF ? 2 : 1 }
    else
      value.scan(/\X/u).size
    end
  end

  def line_span(result, line_index)
    span = result.dig('pages', 0, 'lines', line_index, 'spans', 0)
    {
      span_start: span.fetch('offset'),
      span_end: span.fetch('offset') + span.fetch('length')
    }
  end

  def document_total(result, line_index:, amount: 600)
    line = result.dig('pages', 0, 'lines', line_index)
    digits = amount.to_s
    offset = line.dig('spans', 0, 'offset') + line.fetch('content').index(digits)
    {
      'content' => digits,
      'spans' => [ { 'offset' => offset, 'length' => provider_length(digits, result.fetch('stringIndexType')) } ],
      'valueCurrency' => { 'amount' => amount, 'currencyCode' => 'JPY' }
    }
  end

  def extract(
    result: analyze_result,
    receipt_total: 600,
    receipt_tax: 54,
    existing_tax_details: [
      { rate: nil, net_amount: nil, amount: 54 },
      { rate: nil, net_amount: nil, amount: 54 }
    ],
    excluded_span_ranges: [
      line_span(result, 0).then do |span|
        { span_start: span[:span_start], span_end: line_span(result, 3)[:span_end] }
      end
    ],
    profile: ReceiptAnalysisProfiles.default
  )
    described_class.call(
      analyze_result: result,
      profile: profile,
      receipt_total: receipt_total,
      receipt_tax: receipt_tax,
      existing_tax_details: existing_tax_details,
      excluded_span_ranges: excluded_span_ranges
    )
  end

  it 'strict receipt Totalと単一gross tax targetをbounded evidenceへ変換する' do
    result = extract

    aggregate_failures do
      expect(result.kind).to eq('single_item_receipt_gross_summary')
      expect(result.string_index_type).to eq('textElements')
      expect(result.summary_total).to eq(
        {
          amount: 600,
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[6]',
          page_index: 0,
          line_index: 6,
          string_index_type: 'textElements',
          provider_span_start: 54,
          provider_span_end: 61
        }
      )
      expect(result.gross_tax_target).to eq(
        {
          rate: '0.1',
          net_amount: 546,
          tax_amount: 54,
          gross_amount: 600,
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[4]',
          page_index: 0,
          line_index: 4,
          string_index_type: 'textElements',
          provider_span_start: 32,
          provider_span_end: 43
        }
      )
      expect(result).to be_frozen
      expect(result.kind).to be_frozen
      expect(result.string_index_type).to be_frozen
      expect(result.summary_total).to be_frozen
      expect(result.gross_tax_target).to be_frozen
      expect(result.summary_total[:source_provider]).to be_frozen
      expect(result.summary_total[:string_index_type]).to be_frozen
      expect(result.gross_tax_target[:rate]).to be_frozen
      expect(result.to_h.to_json).not_to match(/匿名商品|raw|content|polygon|description/)
    end
  end

  it 'utf16CodeUnitの日本語・surrogate pair境界をexact spanとして保持する' do
    line_contents = [
      '匿名商品𠮷',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '(内税額 ¥54)',
      '合計 ¥600'
    ]
    result = analyze_result(line_contents: line_contents, string_index_type: 'utf16CodeUnit')

    evidence = extract(result: result)

    aggregate_failures do
      expect(evidence.string_index_type).to eq('utf16CodeUnit')
      expect(evidence.summary_total[:provider_span_start]).to eq(line_span(result, 6)[:span_start])
      expect(evidence.gross_tax_target[:provider_span_start]).to eq(line_span(result, 4)[:span_start])
    end
  end

  it 'labelとdocument Totalが分離したsame-row summaryを共有contractで保持する' do
    result = analyze_result(
      line_contents: [
        '匿名商品',
        '240円/100g',
        '計量 250g',
        '明細計 600円',
        '10%対象計 ¥600',
        '(内税額 ¥54)',
        '合計',
        '¥600'
      ],
      line_layout: {
        6 => { left: 20, top: 180, width: 60 },
        7 => { left: 200, top: 182, width: 70 }
      }
    )
    result['documents'] = [ { 'fields' => { 'Total' => document_total(result, line_index: 7) } } ]

    evidence = extract(result: result)

    aggregate_failures do
      expect(evidence.summary_total).to include(
        amount: 600,
        source_provider: 'azure_item_layout',
        source_field_path: 'pages[0].lines[7]',
        line_index: 7
      )
      expect(evidence.to_h.to_json).not_to match(/匿名商品|raw|content|polygon/)
    end
  end

  it '既存TaxDetailsに同額の不完全entryが重複してもcanonical groupが1件なら許可する' do
    allow(Analysis).to receive(:tax_detail_line_evidence).and_call_original
    evidence = extract(
      existing_tax_details: [
        { 'rate' => nil, 'amount' => 54 },
        { rate: nil, amount: 54 }
      ]
    )

    expect(evidence.gross_tax_target.slice(:rate, :net_amount, :tax_amount, :gross_amount)).to eq(
      rate: '0.1',
      net_amount: 546,
      tax_amount: 54,
      gross_amount: 600
    )
    expect(Analysis).to have_received(:tax_detail_line_evidence).once
  end

  it 'strict summary Totalが0件または2件ならfail-closedにする' do
    missing = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '(内税額 ¥54)',
      'お支払 ¥600'
    ])
    duplicated = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '(内税額 ¥54)',
      '合計 ¥600',
      '総合計 ¥600'
    ])

    aggregate_failures do
      expect(extract(result: missing)).to be_nil
      expect(extract(result: duplicated)).to be_nil
    end
  end

  it 'positive-rate gross tax targetが0件または2件ならfail-closedにする' do
    missing = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '税額 ¥54',
      '合計 ¥600'
    ])
    duplicated = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '10%税込対象 ¥600',
      '(内税額 ¥54)',
      '合計 ¥600'
    ])

    aggregate_failures do
      expect(extract(result: missing)).to be_nil
      expect(extract(result: duplicated)).to be_nil
    end
  end

  it '複数tax groupとmixed-rate receiptを拒否する' do
    result = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥330',
      '(内税額 ¥30)',
      '8%対象計 ¥270',
      '(内税額 ¥20)',
      '合計 ¥600'
    ])

    expect(
      extract(
        result: result,
        receipt_tax: 50,
        existing_tax_details: [],
        excluded_span_ranges: [
          {
            span_start: line_span(result, 0)[:span_start],
            span_end: line_span(result, 3)[:span_end]
          }
        ]
      )
    ).to be_nil
  end

  it '0% targetはgross/netを確定できないため拒否する' do
    result = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '0%対象計 ¥600',
      '(内税額 ¥0)',
      '合計 ¥600'
    ])

    expect(extract(result: result, receipt_tax: 0, existing_tax_details: [])).to be_nil
  end

  it 'summary・tax target・receipt amountの1円不一致をすべて拒否する' do
    summary_mismatch = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '(内税額 ¥54)',
      '合計 ¥601'
    ])
    target_mismatch = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥601',
      '(内税額 ¥54)',
      '合計 ¥600'
    ])

    aggregate_failures do
      expect(extract(result: summary_mismatch)).to be_nil
      expect(extract(result: target_mismatch)).to be_nil
      expect(extract(receipt_total: 601)).to be_nil
      expect(extract(receipt_tax: 55)).to be_nil
    end
  end

  it 'canonical groupの税額がgrossとrateの既存floor算術に一致しなければ拒否する' do
    allow(Analysis).to receive(:tax_detail_line_evidence).and_return(
      [ { rate: BigDecimal('0.1'), net_amount: 545, amount: 55 } ]
    )

    expect(extract(receipt_tax: 55)).to be_nil
  end

  it 'summary Totalまたはgross tax targetがcandidate block spanとoverlapすれば拒否する' do
    result = analyze_result
    summary_span = line_span(result, 6)
    target_span = line_span(result, 4)

    aggregate_failures do
      expect(extract(result: result, excluded_span_ranges: [ summary_span ])).to be_nil
      expect(extract(result: result, excluded_span_ranges: [ target_span ])).to be_nil
    end
  end

  it 'excluded span rangeのnil・空・不正型・overlap・上限超過を拒否する' do
    result = analyze_result
    first = line_span(result, 0)

    invalid_ranges = [
      nil,
      [],
      'range',
      [ { span_start: first[:span_start], span_end: first[:span_start] } ],
      [ { span_start: -1, span_end: first[:span_end] } ],
      [ first.merge(raw_text: '匿名商品') ],
      [ first, first ],
      Array.new(17, first)
    ]

    invalid_ranges.each do |ranges|
      expect(extract(result: result, excluded_span_ranges: ranges)).to be_nil
    end
  end

  it 'provider model・API version・string index type・page countがcontract外なら拒否する' do
    two_pages = analyze_result
    two_pages['pages'] << Marshal.load(Marshal.dump(two_pages['pages'].first))

    aggregate_failures do
      expect(extract(result: analyze_result(model_id: 'unknown'))).to be_nil
      expect(extract(result: analyze_result(api_version: '2025-01-01'))).to be_nil
      expect(extract(result: analyze_result(string_index_type: 'unicodeCodePoint'))).to be_nil
      expect(extract(result: two_pages)).to be_nil
    end
  end

  it 'line content/spanの欠損・top-level content不一致・oversizeを拒否する' do
    missing_span = analyze_result
    missing_span.dig('pages', 0, 'lines', 6).delete('spans')
    mismatched_content = analyze_result
    mismatched_content.dig('pages', 0, 'lines', 6)['content'] = '合計 ¥601'
    oversized = analyze_result
    oversized.dig('pages', 0, 'lines', 0)['content'] = '品' * 513

    aggregate_failures do
      expect(extract(result: missing_span)).to be_nil
      expect(extract(result: mismatched_content)).to be_nil
      expect(extract(result: oversized)).to be_nil
    end
  end

  it 'line spanのnegative・out-of-range・overlapを拒否する' do
    negative = analyze_result
    negative.dig('pages', 0, 'lines', 0, 'spans', 0)['offset'] = -1
    out_of_range = analyze_result
    out_of_range.dig('pages', 0, 'lines', 6, 'spans', 0)['length'] = 10_000_001
    overlapping = analyze_result
    overlapping.dig('pages', 0, 'lines', 1, 'spans', 0)['offset'] = 0

    aggregate_failures do
      expect(extract(result: negative)).to be_nil
      expect(extract(result: out_of_range)).to be_nil
      expect(extract(result: overlapping)).to be_nil
    end
  end

  it 'line index 149と160 byte以下のstructural pathを境界値として許可する' do
    line_contents = Array.new(148) { |index| "証拠#{index}" }
    line_contents << '10%対象計 ¥600'
    line_contents << '合計 ¥600'
    result = analyze_result(line_contents: line_contents)

    evidence = extract(
      result: result,
      excluded_span_ranges: [ line_span(result, 0) ]
    )

    aggregate_failures do
      expect(evidence.summary_total[:line_index]).to eq(149)
      expect(evidence.summary_total[:source_field_path]).to eq('pages[0].lines[149]')
      expect(evidence.summary_total[:source_field_path].bytesize).to be <= 160
    end
  end

  it '151 lineまたは17 existing tax detailsはbounded contract外として拒否する' do
    too_many_lines = analyze_result(line_contents: Array.new(151) { |index| "証拠#{index}" })

    aggregate_failures do
      expect(extract(result: too_many_lines, excluded_span_ranges: [ line_span(too_many_lines, 0) ])).to be_nil
      expect(extract(existing_tax_details: Array.new(17) { { amount: 54 } })).to be_nil
    end
  end

  it 'profile vocabularyを利用しshared extractorへ日本語語彙を直書きしない' do
    profile = ReceiptAnalysisProfiles.default.dup
    allow(profile).to receive(:ocr_strict_receipt_summary_total_line_pattern).and_return(/\A精算額 \d+円\z/)
    allow(profile).to receive(:analysis_tax_target_marker_pattern).and_return(/課税総額/)
    allow(profile).to receive(:analysis_tax_summary_line_pattern).and_return(/\A10%課税総額 ¥600\z/)
    allow(profile).to receive(:amount_tax_detail_gross_pattern).and_return(/課税総額/)
    result = analyze_result(line_contents: [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%課税総額 ¥600',
      '(内税額 ¥54)',
      '精算額 600円'
    ])

    expect(extract(result: result, profile: profile)).not_to be_nil
  end

  it 'unknown fieldを結果へ取り込まず入力を変更しない' do
    source = analyze_result
    source['providerPrivate'] = { 'raw' => 'secret' }
    original = Marshal.load(Marshal.dump(source))

    evidence = extract(result: source)

    aggregate_failures do
      expect(evidence.to_h.keys).to contain_exactly(:kind, :string_index_type, :summary_total, :gross_tax_target)
      expect(evidence.to_h.to_json).not_to include('providerPrivate', 'secret')
      expect(source).to eq(original)
    end
  end

  it 'invalid encoding・NUL/control・oversized receipt valuesをraiseせず拒否する' do
    invalid_encoding = analyze_result
    invalid_encoding['content'] = "\xFF".dup.force_encoding(Encoding::UTF_8)
    nul = analyze_result
    nul.dig('pages', 0, 'lines', 0)['content'] = "匿名\0商品"

    aggregate_failures do
      expect { extract(result: invalid_encoding) }.not_to raise_error
      expect(extract(result: invalid_encoding)).to be_nil
      expect(extract(result: nul)).to be_nil
      expect(extract(receipt_total: 1_000_000_000_000)).to be_nil
      expect(extract(receipt_tax: 1_000_000_000_000)).to be_nil
    end
  end
end
