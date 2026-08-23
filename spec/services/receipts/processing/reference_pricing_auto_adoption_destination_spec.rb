require 'rails_helper'

RSpec.describe Receipts::Processing::ReferencePricingAutoAdoptionDestination do
  def destination_snapshot
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  it 'provider-backedなname prefixとexact sourceだけから一意な新規item proposalを復元する' do
    result = described_class.call(ocr_snapshot: destination_snapshot)

    aggregate_failures do
      expect(result).to be_present
      expect(result.candidate_identity).to eq('azure_line_group_p0_l1_l2_reference_pricing')
      expect(result.destination_identity).to eq(
        'azure_line_group_destination_p0_name_l1_s13_e19_ref_l1_qty_l2'
      )
      expect(result.item_attributes).to include(
        raw_text: '検証品A01',
        suggested_name: '検証品A01',
        confirmed_name: nil,
        price: nil,
        quantity: '2.5',
        quantity_unit_code: 'liter',
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: '120',
        reference_quantity: '1',
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'gross',
        original_line_total: nil,
        line_total: nil
      )
      expect(result.item_attributes).to include(
        quantity_unit_raw: nil,
        reference_quantity_unit_raw: nil
      )
    end
  end

  it 'Azure Items count・proposal count・context lineが変化したsnapshotはfail-closedにする' do
    item_count_mismatch = destination_snapshot.deep_dup
    item_count_mismatch.dig('candidate_counts', 'items')['actual_count'] = 1

    multiple = destination_snapshot.deep_dup
    multiple.dig('candidate_counts', 'reference_pricing_candidates')['actual_count'] = 2

    tampered_line = destination_snapshot.deep_dup
    tampered_line['case_preserved_lines'][1] = '別の商品 税込 120円/1 L'

    aggregate_failures do
      expect(described_class.call(ocr_snapshot: item_count_mismatch)).to be_nil
      expect(described_class.call(ocr_snapshot: multiple)).to be_nil
      expect(described_class.call(ocr_snapshot: tampered_line)).to be_nil
    end
  end

  it 'raw OCR・merchant・summary・金額一致から別destinationを探索しない' do
    snapshot = destination_snapshot.deep_dup
    snapshot['case_preserved_lines'].unshift('検証品A01')

    expect(described_class.call(ocr_snapshot: snapshot)).to be_nil
  end

  it '深すぎるproposalと過大なcount mapを全snapshot再帰変換せずboundedに拒否する' do
    deep_value = { 'leaf' => true }
    64.times { deep_value = { 'nested' => deep_value } }
    deep_proposal = destination_snapshot.deep_dup
    deep_proposal.dig('adoption_proposals')['reference_pricing'] = deep_value

    oversized_counts = destination_snapshot.deep_dup
    oversized_counts['candidate_counts'] = 33.times.to_h { |index| [ "count_#{index}", index ] }

    aggregate_failures do
      expect { described_class.call(ocr_snapshot: deep_proposal) }.not_to raise_error
      expect(described_class.call(ocr_snapshot: deep_proposal)).to be_nil
      expect(described_class.call(ocr_snapshot: oversized_counts)).to be_nil
    end
  end
end
