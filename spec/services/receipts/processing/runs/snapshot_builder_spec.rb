require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
  it 'build params snapshotにはraw source refsやdiagnosticsを含めず安全なownership contractだけを残す' do
    snapshot = described_class.build_params_snapshot(
      receipt_attributes: { total_amount: 100 },
      receipt_items_attributes: [],
      receipt_adjustments_attributes: [],
      receipt_payments_attributes: [],
      receipt_tax_details_attributes: [],
      review_reasons: [],
      ownership_contract: {
        schema_version: 1,
        duplicate_source_owner_count: 1,
        payment_source_purchase_adjustment_count: 2,
        tax_detail_source_effect_count: 3,
        unknown_purchase_tax_allocation_count: 4,
        adjustment_review_required_count: 5,
        source_refs: [ { source_text: 'RAW OCR SOURCE TEXT' } ],
        diagnostics: [ { normalized_text: 'RAW OCR NORMALIZED TEXT' } ]
      }
    )

    aggregate_failures do
      expect(snapshot['ownership_contract']).to eq(
        'schema_version' => 1,
        'duplicate_source_owner_count' => 1,
        'payment_source_purchase_adjustment_count' => 2,
        'tax_detail_source_effect_count' => 3,
        'unknown_purchase_tax_allocation_count' => 4,
        'adjustment_review_required_count' => 5
      )
      expect(snapshot.to_json).not_to include('RAW OCR SOURCE TEXT', 'RAW OCR NORMALIZED TEXT')
      expect(snapshot.to_json).not_to include('source_refs', 'diagnostics')
    end
  end
end
