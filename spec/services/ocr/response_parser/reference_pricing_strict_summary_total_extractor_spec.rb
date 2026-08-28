require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingStrictSummaryTotalExtractor do
  def analyze_result(
    line_contents:,
    line_layout: {},
    string_index_type: 'textElements',
    model_id: 'prebuilt-receipt',
    api_version: '2024-11-30'
  )
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: string_index_type)
    content = line_contents.join("\n")
    offset = 0
    lines = line_contents.map.with_index do |line_content, line_index|
      length = mapper&.length(line_content) || line_content.length
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
      offset += length + (mapper&.length("\n") || 1)
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

  def total_field(result, line_index:, amount: 600)
    line = result.dig('pages', 0, 'lines', line_index)
    digits = amount.to_s
    line_offset = line.dig('spans', 0, 'offset')
    local_offset = line.fetch('content').index(digits)

    {
      'content' => digits,
      'spans' => [ { 'offset' => line_offset + local_offset, 'length' => digits.length } ],
      'valueCurrency' => { 'amount' => amount, 'currencyCode' => 'JPY' }
    }
  end

  def extract(result, total: nil, profile: ReceiptAnalysisProfiles.fetch('JPN'))
    described_class.call(
      analyze_result: result,
      profile: profile,
      total_field: total
    )
  end

  it 'preserves the existing same-line strict summary contract without requiring polygon evidence' do
    result = analyze_result(line_contents: [ '匿名明細 600円', '合計 600円' ])
    result.dig('pages', 0, 'lines').each { |line| line.delete('polygon') }

    summary = extract(result)

    aggregate_failures do
      expect(summary).to have_attributes(amount: 600)
      expect(summary.label_evidence).to include(
        source_field_path: 'pages[0].lines[1]',
        page_index: 0,
        line_index: 1
      )
      expect(summary.amount_evidence).to eq(summary.label_evidence)
      expect(summary.document_total_evidence).to be_nil
    end
  end

  it 'associates a split document Total with the unique label on the same visual row' do
    result = analyze_result(
      line_contents: [ '匿名明細 600円', '合計', '¥600' ],
      line_layout: {
        1 => { left: 20, top: 100, width: 60 },
        2 => { left: 200, top: 101, width: 70 }
      }
    )

    total = total_field(result, line_index: 2)
    summary = extract(result, total:)

    aggregate_failures do
      expect(summary).to have_attributes(amount: 600)
      expect(summary.label_evidence).to include(
        source_field_path: 'pages[0].lines[1]',
        line_index: 1
      )
      expect(summary.amount_evidence).to include(
        source_field_path: 'pages[0].lines[2]',
        line_index: 2,
        provider_span_start: total.dig('spans', 0, 'offset'),
        provider_span_end: total.dig('spans', 0, 'offset') + total.dig('spans', 0, 'length')
      )
      expect(summary.document_total_evidence).to eq(summary.amount_evidence)
      expect(summary.to_h.to_json).not_to match(/匿名明細|raw|content|polygon/)
    end
  end

  it 'supports a two-index provider ordering gap only when geometry proves the same visual row' do
    result = analyze_result(
      line_contents: [ '匿名明細 600円', '合計', '内税 54円', '¥600' ],
      line_layout: {
        1 => { left: 20, top: 100, width: 60 },
        2 => { left: 20, top: 125, width: 90 },
        3 => { left: 200, top: 102, width: 70 }
      }
    )

    summary = extract(result, total: total_field(result, line_index: 3))

    expect(summary).to have_attributes(amount: 600)
  end

  it 'fails closed for a distant, left-side, or third-following amount line' do
    distant = analyze_result(
      line_contents: [ '匿名明細 600円', '合計', '¥600' ],
      line_layout: {
        1 => { left: 20, top: 100, width: 60 },
        2 => { left: 200, top: 130, width: 70 }
      }
    )
    left_side = analyze_result(
      line_contents: [ '匿名明細 600円', '合計', '¥600' ],
      line_layout: {
        1 => { left: 200, top: 100, width: 60 },
        2 => { left: 20, top: 101, width: 70 }
      }
    )
    third_following = analyze_result(
      line_contents: [ '合計', '注記A', '注記B', '¥600' ],
      line_layout: {
        0 => { left: 20, top: 100, width: 60 },
        3 => { left: 200, top: 101, width: 70 }
      }
    )

    aggregate_failures do
      expect(extract(distant, total: total_field(distant, line_index: 2))).to be_nil
      expect(extract(left_side, total: total_field(left_side, line_index: 2))).to be_nil
      expect(extract(third_following, total: total_field(third_following, line_index: 3))).to be_nil
    end
  end

  it 'accepts the measured center-distance boundary and rejects the first value beyond it' do
    boundary = analyze_result(
      line_contents: [ '合計', '¥600' ],
      line_layout: {
        0 => { left: 20, top: 100, width: 60, height: 16 },
        1 => { left: 200, top: 106.4, width: 70, height: 16 }
      }
    )
    beyond = analyze_result(
      line_contents: [ '合計', '¥600' ],
      line_layout: {
        0 => { left: 20, top: 100, width: 60, height: 16 },
        1 => { left: 200, top: 106.401, width: 70, height: 16 }
      }
    )

    aggregate_failures do
      expect(extract(boundary, total: total_field(boundary, line_index: 1))).to have_attributes(amount: 600)
      expect(extract(beyond, total: total_field(beyond, line_index: 1))).to be_nil
    end
  end

  it 'fails closed for duplicate split labels and a document Total span not owned by the amount line' do
    duplicated = analyze_result(
      line_contents: [ '合計', 'TOTAL', '¥600' ],
      line_layout: {
        0 => { left: 20, top: 100, width: 60 },
        1 => { left: 90, top: 101, width: 60 },
        2 => { left: 200, top: 102, width: 70 }
      }
    )
    misplaced = analyze_result(
      line_contents: [ '匿名明細 600円', '合計', '¥600' ],
      line_layout: {
        1 => { left: 20, top: 100, width: 60 },
        2 => { left: 200, top: 101, width: 70 }
      }
    )
    misplaced_total = total_field(misplaced, line_index: 0)

    aggregate_failures do
      expect(extract(duplicated, total: total_field(duplicated, line_index: 2))).to be_nil
      expect(extract(misplaced, total: misplaced_total)).to be_nil
    end
  end

  it 'uses injected profile vocabulary and rejects unsupported or malformed provider boundaries' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_strict_receipt_summary_total_label_line_pattern).and_return(/\AFINAL\z/)
    custom = analyze_result(
      line_contents: [ 'FINAL', '¥600' ],
      line_layout: {
        0 => { left: 20, top: 100, width: 60 },
        1 => { left: 200, top: 101, width: 70 }
      }
    )
    unsupported = custom.deep_dup
    unsupported['stringIndexType'] = 'utf8Byte'
    malformed = custom.deep_dup
    malformed.dig('pages', 0, 'lines', 1, 'spans', 0)['length'] = -1
    malformed_polygon = custom.deep_dup
    malformed_polygon.dig('pages', 0, 'lines', 1)['polygon'] = [ 20, 20, 30 ]

    aggregate_failures do
      expect(extract(custom, total: total_field(custom, line_index: 1), profile:)).to have_attributes(amount: 600)
      expect(extract(unsupported, total: total_field(custom, line_index: 1), profile:)).to be_nil
      expect(extract(malformed, total: total_field(custom, line_index: 1), profile:)).to be_nil
      expect(extract(malformed_polygon, total: total_field(custom, line_index: 1), profile:)).to be_nil
    end
  end
end
