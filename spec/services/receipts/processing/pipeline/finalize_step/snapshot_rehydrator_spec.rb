require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator do
  describe '.ocr' do
    it 'returns nil for blank or non-hash snapshots' do
      aggregate_failures do
        expect(described_class.ocr(nil)).to be_nil
        expect(described_class.ocr({})).to be_nil
        expect(described_class.ocr('invalid')).to be_nil
      end
    end

    it 'restores only the existing OCR result fields from string-key JSON data' do
      result = described_class.ocr(
        'schema_version' => 'receipt_analysis_run_ocr_result_v1',
        'success' => true,
        'lines' => [ 'line', 2 ],
        'case_preserved_lines' => [ 'Line', 2 ],
        'candidates' => { 'store_name' => 'Store' },
        'candidate_counts' => { 'items' => { 'snapshot_count' => 2 } },
        'error_code' => '',
        'meta' => { 'provider' => 'fixture' },
        'truncated' => { 'items' => true },
        'raw_response' => 'not restored'
      )

      expect(result).to eq(
        success: true,
        lines: [ 'line', '2' ],
        case_preserved_lines: [ 'Line', '2' ],
        candidates: { 'store_name' => 'Store' },
        candidate_counts: { 'items' => { 'snapshot_count' => 2 } },
        meta: { 'provider' => 'fixture' }
      )
    end

    it 'uses strict boolean restoration' do
      expect(described_class.ocr('success' => 'true')).to include(success: false)
    end
  end

  describe '.ai' do
    it 'restores the existing AI result fields and collection shapes' do
      result = described_class.ai(
        'schema_version' => 'receipt_analysis_run_ai_normalized_result_v1',
        'success' => true,
        'needs_review' => true,
        'review_reasons' => [ 'ocr_low_confidence' ],
        'receipt_attributes' => { 'purchased_at' => '2026-05-23T10:00:00+09:00' },
        'receipt_items_attributes' => [ { 'raw_text' => 'Item' }, nil ],
        'receipt_adjustments_attributes' => [ { 'amount' => 10 }, nil ],
        'attribute_counts' => { 'receipt_items_attributes' => { 'snapshot_count' => 2 } },
        'meta' => { 'provider' => 'fixture' },
        'prompt' => 'not restored'
      )

      expect(result).to eq(
        success: true,
        needs_review: true,
        review_reasons: [ 'ocr_low_confidence' ],
        receipt_attributes: { 'purchased_at' => '2026-05-23T10:00:00+09:00' },
        receipt_items_attributes: [ { 'raw_text' => 'Item' }, {} ],
        receipt_adjustments_attributes: [ { 'amount' => 10 }, {} ],
        attribute_counts: { 'receipt_items_attributes' => { 'snapshot_count' => 2 } },
        meta: { 'provider' => 'fixture' }
      )
    end

    it 'accepts snapshots without a schema version and uses strict booleans' do
      expect(described_class.ai('success' => 'true', 'needs_review' => 1)).to include(
        success: false,
        needs_review: false
      )
    end

    it 'returns nil for blank or non-hash snapshots' do
      aggregate_failures do
        expect(described_class.ai(nil)).to be_nil
        expect(described_class.ai({})).to be_nil
        expect(described_class.ai('invalid')).to be_nil
      end
    end
  end
end
