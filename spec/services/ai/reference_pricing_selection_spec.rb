require 'rails_helper'

RSpec.describe Ai::ReferencePricingSelection do
  def fixture_path
    Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json')
  end

  def ocr_snapshot
    @ocr_snapshot ||= begin
      result = Ocr::ResponseParser.new(
        response: JSON.parse(fixture_path.read),
        provider: :fixture
      ).call
      Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
    end
  end

  def ledger
    ocr_snapshot.dig('evidence_ledgers', 'reference_pricing')
  end

  def selection_input
    described_class.input_from_ledger(
      ledger,
      context_line_count: ocr_snapshot.fetch('lines').size
    )
  end

  def selected_option
    selection_input.fetch('options').sole
  end

  def valid_output(decision: 'select', reason_code: 'matched_reference_pricing')
    selected = decision == 'select'
    {
      'decision' => decision,
      'candidate_id' => selected ? selected_option.fetch('candidate_id') : nil,
      'destination_id' => selected ? selected_option.fetch('destination_id') : nil,
      'reason_code' => reason_code
    }
  end

  it 'projects a validated ledger to bounded IDs and existing OCR line references' do
    input = selection_input

    aggregate_failures do
      expect(input.keys).to match_array(%w[ledger_checksum options])
      expect(input.fetch('ledger_checksum')).to match(/\A[0-9a-f]{64}\z/)
      expect(input.fetch('options').sole.keys).to match_array(%w[
        candidate_id destination_id evidence_lines
      ])
      expect(input.dig('options', 0, 'evidence_lines')).to eq(
        'product_destination' => 1,
        'reference_price' => 1,
        'reference_quantity' => 1,
        'purchased_quantity' => 2,
        'tax_inclusion' => 1
      )
      expect(input.to_json).not_to include(
        'amount', 'quantity_unit', 'line_total', 'raw_text', 'product_name',
        'merchant', 'polygon', 'source_field_path', 'provider_span_start'
      )
    end
  end

  it 'does not project evidence that points outside the existing OCR context' do
    expect(
      described_class.input_from_ledger(ledger, context_line_count: 2)
    ).to be_nil
  end

  it 'accepts select, reject, and ambiguous decisions without calculating numeric values' do
    selected = described_class.sanitize(output: valid_output, input: selection_input)
    rejected = described_class.sanitize(
      output: valid_output(decision: 'reject', reason_code: 'package_content'),
      input: selection_input
    )
    ambiguous = described_class.sanitize(
      output: valid_output(decision: 'ambiguous', reason_code: 'insufficient_evidence'),
      input: selection_input
    )

    aggregate_failures do
      expect(selected).to include(
        'ledger_checksum' => selection_input.fetch('ledger_checksum'),
        'decision' => 'select',
        'candidate_id' => selected_option.fetch('candidate_id'),
        'destination_id' => selected_option.fetch('destination_id'),
        'reason_code' => 'matched_reference_pricing',
        'validation_state' => 'accepted'
      )
      expect(rejected).to include(
        'decision' => 'reject',
        'reason_code' => 'package_content',
        'validation_state' => 'accepted'
      )
      expect(rejected).not_to have_key('candidate_id')
      expect(ambiguous).to include(
        'decision' => 'ambiguous',
        'reason_code' => 'insufficient_evidence',
        'validation_state' => 'accepted'
      )
      expect([ selected, rejected, ambiguous ].to_json).not_to include(
        'amount', 'quantity', 'unit', 'tax', 'line_total', 'confidence'
      )
    end
  end

  it 'rejects unknown and cross-option pairs without retaining raw model output' do
    second_option = selected_option.deep_dup.merge(
      'candidate_id' => "azure_line_group_evidence_v1_#{'c' * 64}",
      'destination_id' => 'azure_line_group_destination_p0_name_l3_s1_e2_ref_l3_qty_l4'
    )
    two_options = selection_input.deep_dup
    two_options['options'] << second_option
    cross_pair = valid_output.merge('destination_id' => second_option.fetch('destination_id'))
    unknown_pair = valid_output.merge('candidate_id' => "azure_line_group_evidence_v1_#{'0' * 64}")

    results = [ cross_pair, unknown_pair ].map do |output|
      described_class.sanitize(output:, input: two_options)
    end

    results.each do |result|
      expect(result).to eq(
        'ledger_checksum' => selection_input.fetch('ledger_checksum'),
        'validation_state' => 'rejected',
        'validation_reason' => 'unknown_pair'
      )
    end
  end

  it 'rejects missing, malformed, oversized, and decision-inconsistent output fail-neutrally' do
    outputs = {
      'selection_missing' => nil,
      'malformed_selection' => '{not-json}',
      'selection_oversized' => valid_output.merge('unknown' => 'x' * described_class::MAX_OUTPUT_BYTES),
      'decision_field_mismatch' => valid_output(decision: 'reject', reason_code: 'discount').merge(
        'candidate_id' => selected_option.fetch('candidate_id')
      )
    }

    results = outputs.transform_values do |output|
      described_class.sanitize(output:, input: selection_input)
    end

    aggregate_failures do
      results.each do |reason, result|
        expect(result).to include(
          'validation_state' => 'rejected',
          'validation_reason' => reason
        )
        expect(result).not_to have_key('candidate_id')
        expect(result).not_to have_key('destination_id')
      end
      expect(results.to_json).not_to include('{not-json}', 'x' * 100)
    end
  end

  it 'rejects decision and reason combinations from another decision without retaining model IDs' do
    outputs = [
      valid_output(reason_code: 'insufficient_evidence'),
      valid_output(decision: 'reject', reason_code: 'matched_reference_pricing'),
      valid_output(decision: 'ambiguous', reason_code: 'discount')
    ]

    results = outputs.map do |output|
      described_class.sanitize(output:, input: selection_input)
    end

    expect(results).to all(
      eq(
        'ledger_checksum' => selection_input.fetch('ledger_checksum'),
        'validation_state' => 'rejected',
        'validation_reason' => 'invalid_reason'
      )
    )
  end

  it 'accepts at most 16 deterministic options without truncation' do
    base = selected_option
    options = 16.times.map do |index|
      base.deep_dup.merge(
        'candidate_id' => "azure_line_group_evidence_v1_#{index.to_s(16).rjust(64, '0')}",
        'destination_id' => "azure_line_group_destination_p0_name_l#{index}_s1_e2_ref_l#{index}_qty_l#{index + 1}"
      )
    end
    input = selection_input.merge('options' => options)

    aggregate_failures do
      expect(described_class.input?(input)).to be(true)
      expect(described_class.input?(input.merge('options' => options + [ options.first ]))).to be(false)
    end
  end
end
