require 'rails_helper'

RSpec.describe 'Reference pricing tax detail structural evidence persistence' do
  def tax_detail_structural_metadata
    {
      source_provider: 'azure_structured',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      tax_details: [
        {
          tax_detail_index: 0,
          parent: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0]',
            tax_detail_index: 0,
            provider_spans: [
              { provider_span_start: 100, provider_span_end: 120 },
              { provider_span_start: 130, provider_span_end: 150 }
            ]
          },
          rate: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Rate',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 11,
            string_index_type: 'textElements',
            provider_span_start: 110,
            provider_span_end: 112,
            rate: '0.08'
          },
          net_amount: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].NetAmount',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 12,
            string_index_type: 'textElements',
            provider_span_start: 130,
            provider_span_end: 136,
            amount: 593
          },
          tax_amount: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Amount',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 13,
            string_index_type: 'textElements',
            provider_span_start: 140,
            provider_span_end: 145,
            amount: 47
          }
        }
      ]
    }
  end

  def ocr_result
    {
      success: true,
      lines: [],
      case_preserved_lines: [],
      candidates: {
        tax_details: [
          { description: '外税', rate: 0.08, net_amount: 593.0, amount: 47.0 }
        ],
        tax_detail_structural_metadata: tax_detail_structural_metadata
      }
    }
  end

  it 'exact tax detail evidenceだけをadoption proposalへ保存してretry時も同一に復元する' do
    initial = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)
    copied = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(initial)
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(copied)
    proposal = initial.dig('adoption_proposals', 'reference_pricing_tax_details')

    aggregate_failures do
      expect(proposal).to include(
        'schema_version' => 'reference_pricing_tax_detail_structural_evidence_set_v1',
        'creation_stage' => 'ocr_validation',
        'integrity_checksum' => match(/\A[0-9a-f]{64}\z/)
      )
      expect(copied.dig('adoption_proposals', 'reference_pricing_tax_details')).to eq(proposal)
      expect(rehydrated.dig(:adoption_proposals, 'reference_pricing_tax_details')).to eq(proposal)
      expect(rehydrated.dig(:candidates, 'tax_details').sole).to include(
        'rate' => 0.08,
        'net_amount' => 593.0,
        'amount' => 47.0
      )
      expect(proposal.to_json).not_to match(/外税|content|polygon|raw_response/)
    end
  end

  it '改変された構造証拠だけを破棄し通常TaxDetailsを維持する' do
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)
    snapshot.dig('adoption_proposals', 'reference_pricing_tax_details', 'tax_details', 0, 'net_amount')['amount'] = 594

    copied = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(snapshot)
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot)

    aggregate_failures do
      expect(copied.dig('adoption_proposals', 'reference_pricing_tax_details')).to be_nil
      expect(rehydrated.dig(:adoption_proposals, 'reference_pricing_tax_details')).to be_nil
      expect(copied.dig('candidates', 'tax_details').sole).to include(
        'rate' => 0.08,
        'net_amount' => 593.0,
        'amount' => 47.0
      )
      expect(rehydrated.dig(:candidates, 'tax_details').sole).to include(
        'rate' => 0.08,
        'net_amount' => 593.0,
        'amount' => 47.0
      )
    end
  end
end
