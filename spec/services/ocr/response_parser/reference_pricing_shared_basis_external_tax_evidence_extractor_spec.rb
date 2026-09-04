require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxEvidenceExtractor do
  def provider_length(value)
    value.scan(/\X/u).size
  end

  def build_analyze_result(description: '外税', tax_amount_content: '47円')
    line_contents = [
      '例示素材',
      '593円',
      '小計',
      '593円',
      description,
      '8.00%',
      '593円',
      tax_amount_content,
      '合計',
      '640円'
    ]
    content = line_contents.join("\n")
    offset = 0
    lines = line_contents.map.with_index do |line_content, line_index|
      length = provider_length(line_content)
      left = line_index.in?([ 1, 3, 6, 7, 9 ]) ? 220 : 20
      top = 20 + (line_index * 24)
      line = {
        'content' => line_content,
        'polygon' => [ left, top, left + 100, top, left + 100, top + 16, left, top + 16 ],
        'spans' => [ { 'offset' => offset, 'length' => length } ]
      }
      offset += length + 1
      line
    end
    field = lambda do |line_index, value|
      line = lines.fetch(line_index)
      {
        'content' => line.fetch('content'),
        'boundingRegions' => [ { 'pageNumber' => 1, 'polygon' => line.fetch('polygon').deep_dup } ],
        'spans' => [ line.dig('spans', 0).deep_dup ]
      }.merge(value)
    end
    parent_start = lines.fetch(4).dig('spans', 0, 'offset')
    parent_end = lines.fetch(7).dig('spans', 0).then { |span| span.fetch('offset') + span.fetch('length') }
    tax_detail = {
      'content' => line_contents[4..7].join("\n"),
      'boundingRegions' => [
        { 'pageNumber' => 1, 'polygon' => [ 10, 110, 340, 110, 340, 210, 10, 210 ] }
      ],
      'spans' => [ { 'offset' => parent_start, 'length' => parent_end - parent_start } ],
      'valueObject' => {
        'Description' => field.call(4, 'valueString' => description),
        'Rate' => field.call(5, 'valueNumber' => 0.08),
        'NetAmount' => field.call(6, 'valueCurrency' => { 'amount' => 593.0, 'currencyCode' => 'JPY' }),
        'Amount' => field.call(7, 'valueCurrency' => { 'amount' => 47.0, 'currencyCode' => 'JPY' })
      }
    }

    {
      'modelId' => 'prebuilt-receipt',
      'apiVersion' => '2024-11-30',
      'stringIndexType' => 'textElements',
      'content' => content,
      'documents' => [
        {
          'fields' => {
            'Subtotal' => field.call(3, 'valueCurrency' => { 'amount' => 593.0, 'currencyCode' => 'JPY' }),
            'TaxDetails' => { 'type' => 'array', 'valueArray' => [ tax_detail ] },
            'TotalTax' => field.call(7, 'valueCurrency' => { 'amount' => 47.0, 'currencyCode' => 'JPY' }),
            'Total' => field.call(9, 'valueCurrency' => { 'amount' => 640.0, 'currencyCode' => 'JPY' })
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
    metadata = Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor.call(
      analyze_result: result,
      profile: profile
    )
    described_class.call(
      analyze_result: result,
      profile: profile,
      receipt_subtotal: 593,
      receipt_total: 640,
      receipt_tax: 47,
      tax_detail_structural_metadata: metadata
    )
  end

  it '外税semanticとSubtotal・TotalTax・Totalをexact structural evidenceへ束縛する' do
    evidence = extract

    aggregate_failures do
      expect(evidence).to have_attributes(
        kind: 'shared_basis_external_tax_summary',
        string_index_type: 'textElements',
        tax_detail_index: 0
      )
      expect(evidence.subtotal).to include(
        source_field_path: 'documents[0].fields.Subtotal',
        line_index: 3,
        amount: 593
      )
      expect(evidence.document_tax_total).to include(
        source_field_path: 'documents[0].fields.TotalTax',
        line_index: 7,
        amount: 47
      )
      expect(evidence.summary_total).to include(
        source_field_path: 'documents[0].fields.Total',
        line_index: 9,
        amount: 640
      )
      expect(evidence.to_h.to_json).not_to match(/例示素材|外税|content|polygon|description|raw_response/)
    end
  end

  it 'structured値・通常候補値・税detail値の1円境界不一致をfail-closedにする' do
    subtotal_field_mismatch = build_analyze_result
    subtotal_field_mismatch.dig('documents', 0, 'fields', 'Subtotal', 'valueCurrency')['amount'] = 594.0
    tax_alias_mismatch = build_analyze_result
    tax_alias_mismatch.dig('documents', 0, 'fields', 'TotalTax', 'valueCurrency')['amount'] = 48.0
    total_field_mismatch = build_analyze_result
    total_field_mismatch.dig('documents', 0, 'fields', 'Total', 'valueCurrency')['amount'] = 641.0

    aggregate_failures do
      expect(extract(subtotal_field_mismatch)).to be_nil
      expect(extract(tax_alias_mismatch)).to be_nil
      expect(extract(total_field_mismatch)).to be_nil
      expect(described_class.call(
        analyze_result: build_analyze_result,
        profile: ReceiptAnalysisProfiles.fetch('JPN'),
        receipt_subtotal: 594,
        receipt_total: 640,
        receipt_tax: 47,
        tax_detail_structural_metadata: Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor.call(
          analyze_result: build_analyze_result,
          profile: ReceiptAnalysisProfiles.fetch('JPN')
        )
      )).to be_nil
    end
  end

  it '外税semantic欠損・alias span不一致・malformed field・unsupported providerを拒否する' do
    internal_tax = build_analyze_result(description: '内税')
    disjoint_alias = build_analyze_result
    disjoint_alias.dig('documents', 0, 'fields', 'TotalTax', 'spans', 0)
      .replace(disjoint_alias.dig('pages', 0, 'lines', 6, 'spans', 0))
    malformed = build_analyze_result
    malformed.dig('documents', 0, 'fields', 'Subtotal', 'boundingRegions', 0)['polygon'] = [ 1, 2, 3 ]
    unsupported = build_analyze_result.merge('modelId' => 'prebuilt-layout')

    aggregate_failures do
      expect(extract(internal_tax)).to be_nil
      expect(extract(disjoint_alias)).to be_nil
      expect(extract(malformed)).to be_nil
      expect(extract(unsupported)).to be_nil
    end
  end

  it 'document amountの符号を句読点として捨てずfail-closedにする' do
    signed_amounts = [ '+47円', '-47円', '＋47円', '－47円', '−47円' ]

    signed_amounts.each do |tax_amount_content|
      expect(extract(build_analyze_result(tax_amount_content:))).to be_nil
    end
  end

  it '外税分類はinjected profileのexact patternだけを使う' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_shared_basis_external_tax_description_pattern)
      .and_return(/\AEXTERNAL-ONLY\z/)

    aggregate_failures do
      expect(extract(build_analyze_result, profile:)).to be_nil
      expect(extract(build_analyze_result(description: 'EXTERNAL-ONLY'), profile:)).to be_present
    end
  end
end
