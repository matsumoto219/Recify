require 'rails_helper'

RSpec.describe Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor do
  def provider_length(value, index_type = 'textElements')
    return value.encode(Encoding::UTF_16LE).bytesize / 2 if index_type == 'utf16CodeUnit'

    value.scan(/\X/u).size
  end

  def build_analyze_result(
    string_index_type: 'textElements',
    description: '外税',
    rate_content: '8.00%',
    provider_rate: 0.08,
    net_amount_content: '593円',
    provider_net_amount: 593.0,
    tax_amount_content: '47円',
    provider_tax_amount: 47.0
  )
    line_contents = [ description, rate_content, net_amount_content, tax_amount_content ]
    content = line_contents.join("\n")
    offset = 0
    lines = line_contents.map.with_index do |line_content, line_index|
      length = provider_length(line_content, string_index_type)
      left = line_index < 2 ? 20 : 220
      top = 20 + (line_index * 24)
      line = {
        'content' => line_content,
        'polygon' => [ left, top, left + 100, top, left + 100, top + 16, left, top + 16 ],
        'spans' => [ { 'offset' => offset, 'length' => length } ]
      }
      offset += length + provider_length("\n", string_index_type)
      line
    end
    line_span = ->(index) { lines.fetch(index).dig('spans', 0) }
    field = lambda do |line_index, value|
      line = lines.fetch(line_index)
      {
        'content' => line.fetch('content'),
        'boundingRegions' => [ { 'pageNumber' => 1, 'polygon' => line.fetch('polygon').deep_dup } ],
        'spans' => [ line_span.call(line_index).deep_dup ]
      }.merge(value)
    end
    parent_span = lambda do |first_line, last_line|
      first = line_span.call(first_line)
      last = line_span.call(last_line)
      {
        'offset' => first.fetch('offset'),
        'length' => last.fetch('offset') + last.fetch('length') - first.fetch('offset')
      }
    end
    tax_detail = {
      'content' => content,
      'boundingRegions' => [
        { 'pageNumber' => 1, 'polygon' => [ 10, 10, 340, 10, 340, 110, 10, 110 ] }
      ],
      'spans' => [ parent_span.call(0, 1), parent_span.call(2, 3) ],
      'valueObject' => {
        'Description' => field.call(0, 'valueString' => description),
        'Rate' => field.call(1, 'valueNumber' => provider_rate),
        'NetAmount' => field.call(
          2,
          'valueCurrency' => { 'amount' => provider_net_amount, 'currencyCode' => 'JPY' }
        ),
        'Amount' => field.call(
          3,
          'valueCurrency' => { 'amount' => provider_tax_amount, 'currencyCode' => 'JPY' }
        )
      }
    }

    {
      'modelId' => 'prebuilt-receipt',
      'apiVersion' => '2024-11-30',
      'stringIndexType' => string_index_type,
      'content' => content,
      'documents' => [
        {
          'fields' => {
            'TaxDetails' => { 'type' => 'array', 'valueArray' => [ tax_detail ] }
          }
        }
      ],
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

  def extract(result = build_analyze_result, profile: ReceiptAnalysisProfiles.fetch('JPN'))
    described_class.call(analyze_result: result, profile: profile)
  end

  it 'Rate・NetAmount・Amountをparentの個別spanへ結ぶbounded metadataにする' do
    result = extract
    detail = result.tax_details.sole

    aggregate_failures do
      expect(result.to_h).to include(
        source_provider: 'azure_structured',
        provider_model_id: 'prebuilt-receipt',
        provider_api_version: '2024-11-30',
        string_index_type: 'textElements'
      )
      expect(detail.fetch(:parent)).to include(
        source_field_path: 'documents[0].fields.TaxDetails[0]',
        tax_detail_index: 0,
        provider_spans: [
          { provider_span_start: 0, provider_span_end: 8 },
          { provider_span_start: 9, provider_span_end: 17 }
        ]
      )
      expect(detail.fetch(:rate)).to include(
        rate: '0.08',
        source_field_path: 'documents[0].fields.TaxDetails[0].Rate',
        line_index: 1
      )
      expect(detail.fetch(:net_amount)).to include(
        amount: 593,
        source_field_path: 'documents[0].fields.TaxDetails[0].NetAmount',
        line_index: 2
      )
      expect(detail.fetch(:tax_amount)).to include(
        amount: 47,
        source_field_path: 'documents[0].fields.TaxDetails[0].Amount',
        line_index: 3
      )
      expect(detail.fetch(:tax_inclusion_evidence)).to include(
        kind: 'external_tax',
        tax_inclusion: 'net',
        source_field_path: 'documents[0].fields.TaxDetails[0].Description',
        line_index: 0
      )
      expect(result.to_h.to_json).not_to match(/外税|content|polygon|description|raw_response/)
    end
  end

  it '外税semanticはprofileのexact patternだけで分類する' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_shared_basis_external_tax_description_pattern)
      .and_return(/\AEXTERNAL-ONLY\z/)

    default_result = extract
    custom_result = build_analyze_result(description: 'EXTERNAL-ONLY')

    aggregate_failures do
      expect(default_result.tax_details.sole.fetch(:tax_inclusion_evidence)).to be_nil
      expect(extract(custom_result, profile:).tax_details.sole.fetch(:tax_inclusion_evidence)).to include(
        kind: 'external_tax',
        tax_inclusion: 'net'
      )
    end
  end

  it 'utf16CodeUnitでも同じcanonical値とexact ownerを保持する' do
    result = extract(build_analyze_result(string_index_type: 'utf16CodeUnit'))

    aggregate_failures do
      expect(result.string_index_type).to eq('utf16CodeUnit')
      expect(result.tax_details.sole.dig(:rate, :rate)).to eq('0.08')
      expect(result.tax_details.sole.dig(:net_amount, :amount)).to eq(593)
      expect(result.tax_details.sole.dig(:tax_amount, :amount)).to eq(47)
    end
  end

  it 'Rate lexemeとstructured valueが異なる場合はset全体を拒否する' do
    mismatched = build_analyze_result
    mismatched.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Rate'
    )['valueNumber'] = 0.1

    expect(extract(mismatched)).to be_nil
  end

  it '符号付きrateと金額lexemeを正値へ読み替えない' do
    signed_rates = [ '+8%', '-8%', '＋8%', '－8%', '−8%' ]
    signed_amounts = [ '+47円', '-47円', '＋47円', '－47円', '−47円' ]

    aggregate_failures do
      signed_rates.each do |rate_content|
        expect(extract(build_analyze_result(rate_content:))).to be_nil
      end
      signed_amounts.each do |tax_amount_content|
        expect(extract(build_analyze_result(tax_amount_content:))).to be_nil
      end
    end
  end

  it 'percentageは一度だけfractionへ変換し0%・100%・100%超の境界を固定する' do
    aggregate_failures do
      expect(extract(build_analyze_result(rate_content: '0%', provider_rate: 0))).to be_nil
      expect(extract(build_analyze_result(rate_content: '100%', provider_rate: 1))).to be_present
      expect(extract(build_analyze_result(rate_content: '101%', provider_rate: 1.01))).to be_nil
      expect(extract(build_analyze_result(rate_content: '800%', provider_rate: 8))).to be_nil
    end
  end

  it '欠損child・parent外child・重複span・malformed polygonをfail-closedにする' do
    missing = build_analyze_result
    missing.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject').delete('NetAmount')
    outside_parent = build_analyze_result
    outside_parent.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'spans'
    ).replace([ outside_parent.dig('pages', 0, 'lines', 0, 'spans', 0).deep_dup ])
    overlapping_parent = build_analyze_result
    spans = overlapping_parent.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'spans')
    spans[1]['offset'] = spans[0]['offset'] + 1
    malformed_polygon = build_analyze_result
    malformed_polygon.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Amount',
      'boundingRegions', 0
    )['polygon'] = [ 1, 2, 3 ]

    aggregate_failures do
      expect(extract(missing)).to be_nil
      expect(extract(outside_parent)).to be_nil
      expect(extract(overlapping_parent)).to be_nil
      expect(extract(malformed_polygon)).to be_nil
    end
  end

  it 'unsupported provider・oversized collection・multi-span childを拒否する' do
    oversized = build_analyze_result
    entries = oversized.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray')
    entries.replace(Array.new(described_class::MAX_TAX_DETAILS + 1) { entries.sole.deep_dup })
    multi_span_child = build_analyze_result
    rate = multi_span_child.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Rate'
    )
    rate['spans'] << rate['spans'].sole.deep_dup

    aggregate_failures do
      expect(extract(build_analyze_result.merge('modelId' => 'prebuilt-layout'))).to be_nil
      expect(extract(build_analyze_result.merge('apiVersion' => '2099-01-01'))).to be_nil
      expect(extract(build_analyze_result.merge('stringIndexType' => 'utf8Byte'))).to be_nil
      expect(extract(oversized)).to be_nil
      expect(extract(multi_span_child)).to be_nil
    end
  end

  it 'ResponseParserで通常TaxDetailsを変えずexact metadataを別境界に保持する' do
    response = { 'status' => 'succeeded', 'analyzeResult' => build_analyze_result }

    result = Ocr::ResponseParser.new(response:, provider: :fixture).call

    aggregate_failures do
      expect(result.dig(:candidates, :tax_details).sole).to include(
        rate: 0.08,
        net_amount: 593.0,
        amount: 47.0,
        description: '外税'
      )
      expect(result.dig(:candidates, :tax_detail_structural_metadata)).to include(
        source_provider: 'azure_structured',
        provider_model_id: 'prebuilt-receipt',
        provider_api_version: '2024-11-30',
        string_index_type: 'textElements'
      )
      expect(result.dig(:candidates, :tax_detail_structural_metadata, :tax_details).sole).to include(
        tax_detail_index: 0,
        rate: include(rate: '0.08'),
        net_amount: include(amount: 593),
        tax_amount: include(amount: 47)
      )
    end
  end

  it 'inferred・deduplicated TaxDetailsへexact metadataを誤添付しない' do
    inferred = build_analyze_result
    inferred.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject'
    ).delete('NetAmount')
    duplicate = build_analyze_result
    entries = duplicate.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray')
    entries << entries.sole.deep_dup

    inferred_result = Ocr::ResponseParser.new(
      response: { 'status' => 'succeeded', 'analyzeResult' => inferred },
      provider: :fixture
    ).call
    duplicate_result = Ocr::ResponseParser.new(
      response: { 'status' => 'succeeded', 'analyzeResult' => duplicate },
      provider: :fixture
    ).call

    aggregate_failures do
      expect(inferred_result.dig(:candidates, :tax_detail_structural_metadata)).to be_nil
      expect(duplicate_result.dig(:candidates, :tax_detail_structural_metadata)).to be_nil
    end
  end
end
