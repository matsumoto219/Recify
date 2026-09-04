require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingCandidateExtractor do
  def separate_quantity_unit_response
    response = JSON.parse(Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read)
    quantity = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject', 'Quantity')
    quantity['content'] = '342'
    quantity.fetch('spans').sole['length'] = 3
    response
  end

  def extract_response(response)
    analyze_result = response.fetch('analyzeResult')
    described_class.call(
      items: analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray'),
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      content: analyze_result.fetch('content'),
      string_index_type: analyze_result.fetch('stringIndexType')
    )
  end

  it '同一明細の隣接する数量と単位fieldをexactな購入数量として保持する' do
    %w[utf16CodeUnit textElements].each do |index_type|
      response = separate_quantity_unit_response
      response.fetch('analyzeResult')['stringIndexType'] = index_type
      candidate = extract_response(response).sole

      aggregate_failures index_type do
        expect(candidate[:validation_state]).to eq('valid')
        expect(candidate[:rejection_reasons]).to eq([])
        expect(candidate[:purchased_quantity]).to include(amount: '342', unit_code: 'gram')
        expect(candidate.dig(:purchased_quantity, :evidence)).to include(
          source_field_path: 'documents[0].fields.Items[0].Quantity',
          provider_span_start: 17,
          provider_span_end: 20
        )
      end
    end
  end

  it '単位field欠損・値不一致・範囲外・重複spanを購入単位へ昇格しない' do
    mutations = [
      ->(fields) { fields.delete('QuantityUnit') },
      ->(fields) { fields['QuantityUnit']['valueString'] = 'kg' },
      ->(fields) { fields['QuantityUnit']['spans'].sole['offset'] = 999 },
      ->(fields) { fields['QuantityUnit']['spans'] *= 2 },
      ->(fields) { fields['Quantity']['valueNumber'] = 343 }
    ]

    mutations.each do |mutation|
      response = separate_quantity_unit_response
      mutation.call(response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject'))

      expect(extract_response(response).sole[:validation_state]).not_to eq('valid')
    end
  end

  it '商品名に含まれる容量fieldを購入数量へ流用しない' do
    response = separate_quantity_unit_response
    fields = response.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray', 0, 'valueObject')
    fields['Description'].merge!(
      'valueString' => '342g',
      'content' => '342g',
      'spans' => [ { 'offset' => 17, 'length' => 4 } ]
    )

    expect(extract_response(response).sole[:validation_state]).not_to eq('valid')
  end

  it '数量と単位の間は同じ行の空白だけを許し改行を跨いで結合しない' do
    [ ' ', "\t", "\n" ].each do |separator|
      response = separate_quantity_unit_response
      analyze_result = response.fetch('analyzeResult')
      item = analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray').sole
      item['content'] = item.fetch('content').sub('342g', "342#{separator}g")
      analyze_result['content'] = item.fetch('content')
      item.fetch('spans').sole['length'] += separator.length
      %w[QuantityUnit TotalPrice].each do |field_name|
        item.fetch('valueObject').fetch(field_name).fetch('spans').sole['offset'] += separator.length
      end

      candidate = extract_response(response).sole
      if separator == "\n"
        expect(candidate[:validation_state]).not_to eq('valid')
      else
        expect(candidate[:validation_state]).to eq('valid')
      end
    end
  end

  it 'typed proposalの保存とrehydrateで分離fieldのexact sourceを維持する' do
    parsed = Ocr::ResponseParser.new(response: separate_quantity_unit_response, provider: :fixture).call
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(parsed)
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(JSON.parse(JSON.generate(snapshot)))
    proposals = rehydrated.dig(:adoption_proposals, 'item_calculation_modes')

    expect(proposals).to be_present
    option = proposals.sole.fetch('options').find { |entry| entry['pricing_source_kind'] == 'reference_quantity_price' }
    expect(option.fetch('source')).to include(
      'reference_price_amount' => '498',
      'reference_quantity' => '100',
      'purchased_quantity' => '342',
      'purchased_quantity_unit_code' => 'gram'
    )
  end
end
