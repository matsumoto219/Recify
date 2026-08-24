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
        schema_version: 'receipt_analysis_run_ocr_result_v1',
        success: true,
        lines: [ 'line', '2' ],
        case_preserved_lines: [ 'Line', '2' ],
        candidates: { 'store_name' => 'Store' },
        candidate_counts: { 'items' => { 'snapshot_count' => 2 } },
        meta: { 'provider' => 'fixture' },
        truncated: { 'items' => true }
      )
    end

    it 'uses strict boolean restoration' do
      expect(described_class.ocr('success' => 'true')).to include(success: false)
    end

    it 'reference pricing candidatesをOCR snapshotからBuildParams入力まで復元する' do
      candidate = {
        'candidate_id' => 'azure_items_0_reference_pricing',
        'item_index' => 0,
        'validation_state' => 'unsupported',
        'rejection_reasons' => [ 'unsupported_reference_unit', 'unsupported_purchased_unit' ],
        'reference_price' => {
          'amount' => '498',
          'evidence' => {
            'source_provider' => 'azure_structured',
            'source_field_path' => 'documents[0].fields.Items[0].Price',
            'item_index' => 0,
            'provider_span_start' => 10,
            'provider_span_end' => 13
          }
        },
        'reference_quantity' => {
          'amount' => '100',
          'unit_code' => nil,
          'unit_status' => 'unknown',
          'unit_raw' => '杯',
          'origin' => 'explicit',
          'evidence' => {
            'source_provider' => 'azure_structured',
            'source_field_path' => 'documents[0].fields.Items[0].Price',
            'item_index' => 0,
            'provider_span_start' => 14,
            'provider_span_end' => 18
          }
        },
        'purchased_quantity' => {
          'amount' => '2',
          'unit_code' => nil,
          'unit_status' => 'unknown',
          'unit_raw' => '杯',
          'evidence' => {
            'source_provider' => 'azure_structured',
            'source_field_path' => 'documents[0].fields.Items[0].Quantity',
            'item_index' => 0,
            'provider_span_start' => 19,
            'provider_span_end' => 21
          }
        }
      }

      result = described_class.ocr(
        'success' => true,
        'candidates' => {
          'items' => [],
          'reference_pricing_candidates' => [ candidate ]
        },
        'candidate_counts' => {
          'reference_pricing_candidates' => {
            'actual_count' => 1,
            'snapshot_count' => 1
          }
        }
      )

      aggregate_failures do
        expect(result.dig(:candidates, 'reference_pricing_candidates')).to eq([ candidate ])
        expect(result.dig(:candidate_counts, 'reference_pricing_candidates')).to eq(
          'actual_count' => 1,
          'snapshot_count' => 1
        )

        build_params = Analysis.build_receipt_params(ocr_result: result, ai_result: nil)
        expect(build_params[:reference_pricing_candidates]).to eq([ candidate.deep_symbolize_keys ])
        expect(build_params.fetch(:receipt_items_attributes)).to be_empty
      end
    end

    it 'valid typed adoption proposalだけをFinalize専用OCR resultへ復元する' do
      raw_json = JSON.parse(
        Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
      )
      ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)

      result = described_class.ocr(JSON.parse(JSON.generate(snapshot)))

      aggregate_failures do
        expect(result[:schema_version]).to eq('receipt_analysis_run_ocr_result_v1')
        expect(result.dig(:adoption_proposals, 'reference_pricing')).to eq(
          snapshot.dig('adoption_proposals', 'reference_pricing')
        )
        expect(result.dig(:adoption_proposals, 'reference_pricing').to_json).not_to include(
          '検証品A01',
          'polygon',
          'provider_raw_response'
        )
      end
    end

    it 'valid evidence ledgerだけをFinalize専用OCR resultへ復元する' do
      raw_json = JSON.parse(
        Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
      )
      ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)

      result = described_class.ocr(JSON.parse(JSON.generate(snapshot)))

      aggregate_failures do
        expect(result.dig(:evidence_ledgers, 'reference_pricing')).to eq(
          snapshot.dig('evidence_ledgers', 'reference_pricing')
        )
        expect(result.dig(:evidence_ledgers, 'reference_pricing').to_json).not_to include(
          '検証品A01',
          '120円',
          '2.5 L',
          'polygon',
          'provider_raw_response'
        )
      end
    end

    it 'malformed evidence ledgerだけを除外しold snapshot absenceを維持する' do
      raw_json = JSON.parse(
        Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
      )
      ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)
      snapshot.dig('evidence_ledgers', 'reference_pricing')['schema_version'] = 'unknown'

      aggregate_failures do
        malformed = described_class.ocr(snapshot)
        old = described_class.ocr('success' => true)

        expect(malformed).not_to have_key(:evidence_ledgers)
        expect(malformed.dig(:candidates, 'reference_pricing_candidates')).to be_present
        expect(malformed.dig(:adoption_proposals, 'reference_pricing')).to be_present
        expect(old).not_to have_key(:evidence_ledgers)
      end
    end

    it 'malformed adoption proposalを除外しold snapshot absenceを維持する' do
      raw_json = JSON.parse(
        Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
      )
      ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)
      snapshot.dig('adoption_proposals', 'reference_pricing')['schema_version'] = 'unknown'

      aggregate_failures do
        expect(described_class.ocr(snapshot)).not_to have_key(:adoption_proposals)
        expect(described_class.ocr('success' => true)).not_to have_key(:adoption_proposals)
      end
    end
  end

  describe '.ai' do
    it 'shadow selectionをFinalize入力へ昇格しない' do
      result = described_class.ai(
        'success' => true,
        'needs_review' => false,
        'review_reasons' => [],
        'reference_pricing_selection' => {
          'ledger_checksum' => 'a' * 64,
          'decision' => 'select',
          'candidate_id' => "azure_line_group_evidence_v1_#{'b' * 64}",
          'destination_id' => 'azure_line_group_destination_p0_name_l1_s1_e2_ref_l1_qty_l2',
          'reason_code' => 'matched_reference_pricing',
          'validation_state' => 'accepted',
          'validation_reason' => 'accepted'
        }
      )

      aggregate_failures do
        expect(result).to include(success: true, needs_review: false, review_reasons: [])
        expect(result).not_to have_key(:reference_pricing_selection)
        expect(result.to_json).not_to include('azure_line_group_evidence_v1')
      end
    end

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

    it 'keeps JSON timestamp strings unchanged for downstream parsing and casting' do
      result = described_class.ai(
        'receipt_attributes' => {
          'purchased_at' => '2026-05-23T10:00:00+09:00',
          'ocr_completed_at' => '2026-05-23T10:01:00+09:00'
        }
      )

      expect(result.fetch(:receipt_attributes)).to include(
        'purchased_at' => '2026-05-23T10:00:00+09:00',
        'ocr_completed_at' => '2026-05-23T10:01:00+09:00'
      )
    end

    it 'accepts snapshots without a schema version and uses strict booleans' do
      expect(described_class.ai('success' => 'true', 'needs_review' => 1)).to include(
        success: false,
        needs_review: false
      )
    end

    it 'legacy snapshotのinvalid categoryを復元せず未分類の確認状態へ安全化する' do
      result = described_class.ai(
        'success' => true,
        'needs_review' => false,
        'review_reasons' => [],
        'receipt_items_attributes' => [
          { 'index' => 0, 'category' => 'unknown_category', 'needs_review' => false }
        ]
      )
      item = result.fetch(:receipt_items_attributes).first

      aggregate_failures do
        expect(item).not_to have_key('category')
        expect(item['needs_review']).to be(true)
        expect(item['review_reasons']).to include('item_category_uncertain')
        expect(result[:needs_review]).to be(true)
        expect(result[:review_reasons]).to include('item_category_uncertain')
        expect(result.to_json).not_to include('unknown_category')
      end
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
