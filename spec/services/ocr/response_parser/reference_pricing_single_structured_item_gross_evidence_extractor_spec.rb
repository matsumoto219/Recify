require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossEvidenceExtractor do
  def provider_length(value, index_type = 'textElements')
    return value.encode(Encoding::UTF_16LE).bytesize / 2 if index_type == 'utf16CodeUnit'

    value.scan(/\X/u).size
  end

  def build_analyze_result(
    tax_description: '内消費税等',
    tax_amount: 54,
    total_amount: 600,
    string_index_type: 'textElements'
  )
    line_contents = [
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '600円',
      tax_description,
      "¥#{tax_amount}",
      '合計',
      "¥#{total_amount}"
    ]
    content = line_contents.join("\n")
    offset = 0
    lines = line_contents.map.with_index do |line_content, line_index|
      length = provider_length(line_content, string_index_type)
      left = line_index == 7 ? 200 : 20
      top = line_index == 7 ? 166 : 20 + (line_index * 24)
      line = {
        'content' => line_content,
        'boundingRegions' => [
          { 'pageNumber' => 1, 'polygon' => [ left, top, left + 120, top, left + 120, top + 16, left, top + 16 ] }
        ],
        'polygon' => [ left, top, left + 120, top, left + 120, top + 16, left, top + 16 ],
        'spans' => [ { 'offset' => offset, 'length' => length } ]
      }
      offset += length + provider_length("\n", string_index_type)
      line
    end
    line_span = ->(line_index) { lines.fetch(line_index).dig('spans', 0) }
    range = lambda do |first_line, last_line|
      first = line_span.call(first_line)
      last = line_span.call(last_line)
      {
        'offset' => first.fetch('offset'),
        'length' => last.fetch('offset') + last.fetch('length') - first.fetch('offset')
      }
    end
    field = lambda do |line_index, value|
      span = line_span.call(line_index)
      {
        'content' => line_contents.fetch(line_index),
        'boundingRegions' => lines.fetch(line_index).fetch('boundingRegions').deep_dup,
        'spans' => [ span.deep_dup ]
      }.merge(value)
    end
    item = {
      'content' => line_contents.first(4).join("\n"),
      'boundingRegions' => [
        { 'pageNumber' => 1, 'polygon' => [ 10, 10, 400, 10, 400, 105, 10, 105 ] }
      ],
      'spans' => [ range.call(0, 3) ],
      'valueObject' => {
        'Description' => field.call(0, 'valueString' => line_contents.fetch(0)),
        'Price' => field.call(
          1,
          'valueCurrency' => { 'amount' => 240.0, 'currencyCode' => 'JPY' }
        ),
        'Quantity' => field.call(2, 'valueNumber' => 250.0),
        'QuantityUnit' => {
          'content' => 'g',
          'boundingRegions' => lines.fetch(2).fetch('boundingRegions').deep_dup,
          'spans' => [
            {
              'offset' => line_span.call(2).fetch('offset') + provider_length('250', string_index_type),
              'length' => provider_length('g', string_index_type)
            }
          ],
          'valueString' => 'g'
        },
        'TotalPrice' => field.call(
          3,
          'valueCurrency' => { 'amount' => total_amount.to_f, 'currencyCode' => 'JPY' }
        )
      }
    }
    tax_detail = {
      'content' => line_contents.slice(4, 2).join("\n"),
      'boundingRegions' => [
        { 'pageNumber' => 1, 'polygon' => [ 10, 108, 400, 108, 400, 158, 10, 158 ] }
      ],
      'spans' => [ range.call(4, 5) ],
      'valueObject' => {
        'Description' => field.call(4, 'valueString' => tax_description),
        'Amount' => field.call(
          5,
          'valueCurrency' => { 'amount' => tax_amount.to_f, 'currencyCode' => 'JPY' }
        )
      }
    }
    total_line = lines.fetch(7)
    total_digits = total_amount.to_s
    total_span = {
      'offset' => total_line.dig('spans', 0, 'offset') + provider_length('¥', string_index_type),
      'length' => provider_length(total_digits, string_index_type)
    }

    {
      'modelId' => 'prebuilt-receipt',
      'apiVersion' => '2024-11-30',
      'stringIndexType' => string_index_type,
      'content' => content,
      'documents' => [
        {
          'fields' => {
            'Items' => { 'type' => 'array', 'valueArray' => [ item ] },
            'TaxDetails' => { 'type' => 'array', 'valueArray' => [ tax_detail ] },
            'Total' => {
              'content' => total_digits,
              'boundingRegions' => lines.fetch(7).fetch('boundingRegions').deep_dup,
              'spans' => [ total_span ],
              'valueCurrency' => { 'amount' => total_amount.to_f, 'currencyCode' => 'JPY' }
            },
            'TotalTax' => tax_detail.dig('valueObject', 'Amount').deep_dup
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

  def extract(
    result = build_analyze_result,
    receipt_total: 600,
    receipt_tax: 54,
    profile: ReceiptAnalysisProfiles.fetch('JPN')
  )
    described_class.call(
      analyze_result: result,
      profile: profile,
      receipt_total: receipt_total,
      receipt_tax: receipt_tax
    )
  end

  it 'single native Item外のexact内税TaxDetailsとsummary Totalをbounded evidenceへ変換する' do
    evidence = extract

    aggregate_failures do
      expect(evidence.kind).to eq('single_item_receipt_inner_tax_summary')
      expect(evidence.string_index_type).to eq('textElements')
      expect(evidence.item_parent).to include(
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.Items[0]',
        item_index: 0
      )
      expect(evidence.tax_detail_parent).to include(
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.TaxDetails[0]',
        tax_detail_index: 0
      )
      expect(evidence.tax_description).to include(
        source_field_path: 'documents[0].fields.TaxDetails[0].Description',
        page_index: 0,
        line_index: 4
      )
      expect(evidence.tax_amount).to include(
        amount: 54,
        source_field_path: 'documents[0].fields.TaxDetails[0].Amount',
        page_index: 0,
        line_index: 5
      )
      expect(evidence.document_tax_total).to include(
        amount: 54,
        source_field_path: 'documents[0].fields.TotalTax',
        page_index: 0,
        line_index: 5
      )
      expect(evidence.summary_total).to include(
        amount: 600,
        source_provider: 'azure_document_total',
        source_field_path: 'pages[0].lines[7]',
        page_index: 0,
        line_index: 7
      )
      expect(evidence.to_h.to_json).not_to match(/匿名商品|内消費税|raw|content|polygon|description_text/)
    end
  end

  it 'native Item候補をexact内税TaxDetailsとsummary Totalからgross validへ昇格する' do
    response = {
      'status' => 'succeeded',
      'analyzeResult' => build_analyze_result
    }

    result = Ocr::ResponseParser.new(response:, provider: :fixture).call
    reference_candidate = result.dig(:candidates, :reference_pricing_candidates).sole
    mode_candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole

    aggregate_failures do
      expect(result.fetch(:candidates)).to include(
        total_amount: 600,
        tax_amount: 54,
        adjustment_candidates: []
      )
      expect(reference_candidate).to include(
        candidate_id: 'azure_items_0_reference_pricing',
        validation_state: 'valid',
        rejection_reasons: [],
        reference_price_tax_inclusion: 'gross'
      )
      expect(reference_candidate.dig(:tax_inclusion_evidence, :kind)).to eq(
        'single_item_receipt_inner_tax_summary'
      )
      expect(mode_candidate).to include(
        candidate_id: 'azure_items_0_item_calculation_mode',
        item_index: 0,
        conflicts: include('reference_expression')
      )
    end
  end

  it 'utf16CodeUnitでもstructured childとline ownerのexact spanを維持する' do
    evidence = extract(build_analyze_result(string_index_type: 'utf16CodeUnit'))

    aggregate_failures do
      expect(evidence.string_index_type).to eq('utf16CodeUnit')
      expect(evidence.tax_description[:string_index_type]).to eq('utf16CodeUnit')
      expect(evidence.tax_amount[:string_index_type]).to eq('utf16CodeUnit')
      expect(evidence.document_tax_total[:string_index_type]).to eq('utf16CodeUnit')
      expect(evidence.summary_total[:string_index_type]).to eq('utf16CodeUnit')
    end
  end

  it 'single native Itemの非連続spanを各fragmentのexact contentから検証する' do
    response = build_analyze_result
    item = response.dig('documents', 0, 'fields', 'Items', 'valueArray', 0)
    lines = response.dig('pages', 0, 'lines')
    first = lines.fetch(0).dig('spans', 0).deep_dup
    second_start = lines.fetch(1).dig('spans', 0, 'offset')
    second_end = lines.fetch(3).dig('spans', 0).then { |span| span.fetch('offset') + span.fetch('length') }
    item['spans'] = [ first, { 'offset' => second_start, 'length' => second_end - second_start } ]

    evidence = extract(response)

    expect(evidence.item_parent).to include(
      provider_span_start: first.fetch('offset'),
      provider_span_end: second_end
    )
  end

  it 'single native Itemの重複・逆順・過剰fragmentを拒否する' do
    response = build_analyze_result
    item = response.dig('documents', 0, 'fields', 'Items', 'valueArray', 0)
    span = item.fetch('spans').sole
    midpoint = span.fetch('offset') + 4
    fragments = [
      { 'offset' => span.fetch('offset'), 'length' => 8 },
      { 'offset' => midpoint, 'length' => span.fetch('length') - 4 }
    ]

    aggregate_failures do
      item['spans'] = fragments
      expect(extract(response)).to be_nil

      item['spans'] = fragments.reverse
      expect(extract(response)).to be_nil

      item['spans'] = [ span.deep_dup ] * 17
      expect(extract(response)).to be_nil
    end
  end

  it 'parserで保持されるwhole Floatのreceipt taxはexact lexemeとの照合値に限定する' do
    evidence = extract(receipt_total: 600.0, receipt_tax: 54.0)

    aggregate_failures do
      expect(evidence.tax_amount[:amount]).to eq(54)
      expect(evidence.document_tax_total[:amount]).to eq(54)
      expect(evidence.summary_total[:amount]).to eq(600)
    end
  end

  it '内税と内消費税等だけをstrict descriptionとして受け入れる' do
    aggregate_failures do
      expect(extract(build_analyze_result(tax_description: '内税'))).to be_present
      expect(extract(build_analyze_result(tax_description: '消費税'))).to be_nil
      expect(extract(build_analyze_result(tax_description: '外税'))).to be_nil
      expect(extract(build_analyze_result(tax_description: '内税対象'))).to be_nil
    end
  end

  it 'country-specific description patternをinjected profileから解決する' do
    profile = ReceiptAnalysisProfiles.fetch('JPN').dup
    allow(profile).to receive(
      :ocr_reference_pricing_single_structured_item_inner_tax_description_pattern
    ).and_return(/\A専用内税\z/)

    aggregate_failures do
      expect(extract(profile: profile)).to be_nil
      expect(extract(build_analyze_result(tax_description: '専用内税'), profile: profile)).to be_present
    end
  end

  it 'raw ItemまたはTaxDetailsがexactly oneでない場合はfail-closedにする' do
    two_items = build_analyze_result
    items = two_items.dig('documents', 0, 'fields', 'Items', 'valueArray')
    items << items.sole.deep_dup
    two_tax_details = build_analyze_result
    tax_details = two_tax_details.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray')
    tax_details << tax_details.sole.deep_dup

    aggregate_failures do
      expect(extract(two_items)).to be_nil
      expect(extract(two_tax_details)).to be_nil
      expect(extract(build_analyze_result.deep_merge(
        'documents' => [ { 'fields' => { 'Items' => { 'valueArray' => [] } } } ]
      ))).to be_nil
    end
  end

  it 'descriptionとAmountのstructured binding不整合を拒否する' do
    mismatched_description = build_analyze_result
    mismatched_description.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Description'
    )['valueString'] = '外税'
    mismatched_amount = build_analyze_result
    mismatched_amount.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Amount', 'valueCurrency'
    )['amount'] = 55.0
    non_jpy = build_analyze_result
    non_jpy.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Amount', 'valueCurrency'
    )['currencyCode'] = 'USD'
    mismatched_total_tax = build_analyze_result
    mismatched_total_tax.dig('documents', 0, 'fields', 'TotalTax', 'valueCurrency')['amount'] = 55.0

    aggregate_failures do
      expect(extract(mismatched_description)).to be_nil
      expect(extract(mismatched_amount)).to be_nil
      expect(extract(non_jpy)).to be_nil
      expect(extract(mismatched_total_tax)).to be_nil
      expect(extract(build_analyze_result, receipt_tax: 55)).to be_nil
    end
  end

  it 'tax childrenがparent外・重複・Item内にある場合は拒否する' do
    outside_parent = build_analyze_result
    outside_parent.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'spans', 0)['length'] = 2
    overlapping_children = build_analyze_result
    description = overlapping_children.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Description', 'spans', 0
    )
    overlapping_children.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Amount', 'spans'
    ).replace([ description.deep_dup ])
    overlapping_parent = build_analyze_result
    item_span = overlapping_parent.dig('documents', 0, 'fields', 'Items', 'valueArray', 0, 'spans', 0)
    overlapping_parent.dig('documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'spans')
      .replace([ item_span.deep_dup ])
    malformed_polygon = build_analyze_result
    malformed_polygon.dig(
      'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0, 'valueObject', 'Amount', 'boundingRegions', 0
    )['polygon'] = [ 1, 2, 3 ]

    aggregate_failures do
      expect(extract(outside_parent)).to be_nil
      expect(extract(overlapping_children)).to be_nil
      expect(extract(overlapping_parent)).to be_nil
      expect(extract(malformed_polygon)).to be_nil
    end
  end

  it 'summary Totalの欠損・不一致とunsupported provider contractを拒否する' do
    missing_total = build_analyze_result
    missing_total.dig('documents', 0, 'fields').delete('Total')
    wrong_model = build_analyze_result.merge('modelId' => 'prebuilt-layout')
    unknown_index = build_analyze_result.merge('stringIndexType' => 'utf8Byte')

    aggregate_failures do
      expect(extract(missing_total)).to be_nil
      expect(extract(build_analyze_result(total_amount: 601))).to be_nil
      expect(extract(wrong_model)).to be_nil
      expect(extract(unknown_index)).to be_nil
    end
  end
end
