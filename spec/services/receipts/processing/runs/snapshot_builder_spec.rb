require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
  it 'invalid categoryを保存せず未分類の確認状態だけをsnapshotへ残す' do
    snapshot = described_class.ai_normalized_result_snapshot(
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_items_attributes: [
        { index: 0, category: 'unknown_category', needs_review: false }
      ]
    )
    item = snapshot.fetch('receipt_items_attributes').first

    aggregate_failures do
      expect(item).not_to have_key('category')
      expect(item['needs_review']).to be(true)
      expect(item['review_reasons']).to include('item_category_uncertain')
      expect(snapshot['needs_review']).to be(true)
      expect(snapshot['review_reasons']).to include('item_category_uncertain')
      expect(snapshot.to_json).not_to include('unknown_category')
    end
  end

  it '明示されたotherはsnapshotでも独立した有効categoryとして保持する' do
    snapshot = described_class.ai_normalized_result_snapshot(
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_items_attributes: [
        { index: 0, category: 'other', needs_review: false }
      ]
    )

    expect(snapshot.dig('receipt_items_attributes', 0, 'category')).to eq('other')
  end

  it '前後空白を含むcanonical categoryを正規化してsnapshotへ保持する' do
    snapshot = described_class.ai_normalized_result_snapshot(
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_items_attributes: [
        { index: 0, category: ' other ', needs_review: false }
      ]
    )
    item = snapshot.fetch('receipt_items_attributes').first

    aggregate_failures do
      expect(item['category']).to eq('other')
      expect(item['needs_review']).to be(false)
      expect(item.fetch('review_reasons', [])).not_to include('item_category_uncertain')
      expect(snapshot['needs_review']).to be(false)
    end
  end

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
