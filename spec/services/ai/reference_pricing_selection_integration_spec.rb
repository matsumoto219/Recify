require 'rails_helper'

RSpec.describe 'AI reference pricing shadow selection integration' do
  def fixture_path
    Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json')
  end

  def selection_input
    @selection_input ||= begin
      ocr_result = Ocr::ResponseParser.new(
        response: JSON.parse(fixture_path.read),
        provider: :fixture
      ).call
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ocr_result)
      Ai::ReferencePricingSelection.input_from_ledger(
        snapshot.dig('evidence_ledgers', 'reference_pricing'),
        context_line_count: snapshot.fetch('lines').size
      )
    end
  end

  def base_payload
    {
      'is_receipt' => true,
      'is_receipt_confidence' => 0.9,
      'document_type' => 'receipt',
      'rejection_reason' => nil,
      'store' => {
        'store_name' => 'SYNTH STORE',
        'store_address' => nil,
        'store_phone_number' => nil
      },
      'purchase' => { 'purchased_at_text' => '2026-08-24 12:00' },
      'payment' => { 'payment_method' => 'cash' },
      'items' => [],
      'receipt_adjustments' => [],
      'needs_review' => false,
      'review_reasons' => []
    }
  end

  def valid_selection
    option = selection_input.fetch('options').sole
    {
      'decision' => 'select',
      'candidate_id' => option.fetch('candidate_id'),
      'destination_id' => option.fetch('destination_id'),
      'reason_code' => 'matched_reference_pricing'
    }
  end

  it 'adds a sanitized selection to the existing AI result without changing review state' do
    result = Ai::ResponseParser.parse(
      base_payload.merge('reference_pricing_selection' => valid_selection),
      provider: 'openai',
      reference_pricing_options: selection_input
    )

    aggregate_failures do
      expect(result).to include(success: true, needs_review: false, review_reasons: [])
      expect(result.fetch(:reference_pricing_selection)).to include(
        'decision' => 'select',
        'validation_state' => 'accepted'
      )
      expect(result).not_to have_key(:pricing_source_kind)
      expect(result.to_json).not_to include(
        'reference_price_amount', 'reference_quantity', 'purchased_quantity', 'line_total'
      )
    end
  end

  it 'discards only an invalid selection and preserves the base AI result' do
    invalid = valid_selection.merge(
      'candidate_id' => "azure_line_group_evidence_v1_#{'0' * 64}"
    )
    result = Ai::ResponseParser.parse(
      base_payload.merge('reference_pricing_selection' => invalid),
      provider: 'openai',
      reference_pricing_options: selection_input
    )

    aggregate_failures do
      expect(result).to include(success: true, needs_review: false, review_reasons: [], error_code: nil)
      expect(result.fetch(:reference_pricing_selection)).to include(
        'validation_state' => 'rejected',
        'validation_reason' => 'unknown_pair'
      )
    end
  end

  it 'ignores unsolicited selection output when no ledger options were sent' do
    result = Ai::ResponseParser.parse(
      base_payload.merge('reference_pricing_selection' => valid_selection),
      provider: 'openai'
    )

    aggregate_failures do
      expect(result).to include(success: true, needs_review: false, review_reasons: [])
      expect(result).not_to have_key(:reference_pricing_selection)
      expect(result.to_json).not_to include(selection_input.fetch('ledger_checksum'))
    end
  end
end
