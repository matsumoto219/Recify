require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ReferencePricingAdoptionProposal do
  def destination_ocr_result
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def valid_snapshot
    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(destination_ocr_result)
  end

  it 'fixed v1 proposalを入力非破壊でexact round-tripする' do
    snapshot = valid_snapshot
    proposal = snapshot.dig('adoption_proposals', 'reference_pricing')
    source = Marshal.load(Marshal.dump(proposal))

    restored = described_class.from_snapshot(proposal, ocr_snapshot: snapshot)

    aggregate_failures do
      expect(restored).to eq(proposal)
      expect(proposal).to eq(source)
      expect(restored.dig('reference_price', 'amount')).to eq('120')
      expect(restored.dig('reference_quantity', 'amount')).to eq('1')
      expect(restored.dig('purchased_quantity', 'amount')).to eq('2.5')
      expect(restored.fetch('integrity_checksum')).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  it 'unknown version/field・型違い・partial・identity不一致・bounds超過をproposal全体で拒否する' do
    snapshot = valid_snapshot
    proposal = snapshot.dig('adoption_proposals', 'reference_pricing')
    mutations = [
      proposal.merge('schema_version' => 'reference_pricing_adoption_proposal_v2'),
      proposal.merge('unknown' => true),
      proposal.deep_merge('reference_price' => { 'amount' => 120.0 }),
      proposal.deep_merge('reference_price' => { 'amount' => '01' }),
      proposal.deep_merge('reference_price' => { 'amount' => '120.0' }),
      proposal.deep_merge('reference_price' => { 'amount' => '121' }),
      proposal.deep_merge('reference_quantity' => { 'unit_code' => 'unknown' }),
      proposal.deep_merge('purchased_quantity' => { 'unit_code' => 'gram' }),
      proposal.except('destination'),
      proposal.deep_merge('destination' => { 'identity' => 'mismatched' }),
      proposal.deep_merge(
        'destination' => {
          'evidence' => {
            'provider_span_end' => 10_000_001
          }
        }
      ),
      proposal.merge('candidate_id' => 'x' * 129),
      proposal.merge('integrity_checksum' => '0' * 64),
      proposal.merge('reference_price_tax_inclusion' => 'net'),
      proposal.deep_merge('corroboration' => { 'state' => 'mismatched' }),
      proposal.deep_merge(
        'destination' => {
          'evidence' => {
            'word_spans' => proposal.dig('destination', 'evidence', 'word_spans').map.with_index do |span, index|
              index.zero? ? span.merge('source_field_path' => 'pages[0].words[99]') : span
            end
          }
        }
      )
    ]

    mutations.each do |mutation|
      expect {
        expect(described_class.from_snapshot(mutation, ocr_snapshot: snapshot)).to be_nil
      }.not_to raise_error
    end
  end

  it 'candidate/destination structural evidence・case line・truncationとの不一致を拒否する' do
    snapshot = valid_snapshot
    proposal = snapshot.dig('adoption_proposals', 'reference_pricing')
    contexts = [
      snapshot.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [
            snapshot.dig('candidates', 'reference_pricing_candidates', 0).merge(
              'candidate_id' => 'azure_line_group_p0_l8_l9_reference_pricing'
            )
          ]
        }
      ),
      snapshot.deep_merge('case_preserved_lines' => [ nil, 'changed' ]),
      snapshot.deep_merge(
        'case_preserved_lines' => snapshot.fetch('case_preserved_lines').map.with_index do |line, index|
          index == 1 ? line.sub('検証品A01', '合計額ABC') : line
        end
      ),
      snapshot.deep_merge(
        'case_preserved_lines' => snapshot.fetch('case_preserved_lines').map.with_index do |line, index|
          index == 1 ? line.sub('検証品A01', '検証品B02') : line
        end
      ),
      snapshot.deep_merge(
        'case_preserved_lines' => snapshot.fetch('case_preserved_lines').map.with_index do |line, index|
          index == 2 ? line.sub('2.5', '2.6') : line
        end
      ),
      snapshot.merge(
        'case_preserved_lines' => snapshot.fetch('case_preserved_lines') + [ '検証品A01' ]
      ),
      snapshot.except('schema_version'),
      snapshot.merge('schema_version' => 'receipt_analysis_run_ocr_result_v2'),
      snapshot.deep_merge('truncated' => { 'case_preserved_lines' => true }),
      snapshot.deep_merge(
        'candidate_counts' => {
          'reference_pricing_candidates' => { 'actual_count' => 2, 'snapshot_count' => 1 }
        }
      )
    ]

    contexts.each do |context|
      expect(described_class.from_snapshot(proposal, ocr_snapshot: context)).to be_nil
    end
  end

  it 'deep/oversized・invalid encoding・control characterをboundedに拒否する' do
    snapshot = valid_snapshot
    proposal = snapshot.dig('adoption_proposals', 'reference_pricing')
    deep = {}
    cursor = deep
    3_000.times do
      cursor['nested'] = {}
      cursor = cursor['nested']
    end
    invalid_encoding = proposal.deep_dup
    invalid_encoding['candidate_id'] = "\xFF".dup.force_encoding(Encoding::UTF_8)
    control = proposal.merge('candidate_id' => "candidate\u0000id")
    zero_width = proposal.merge('candidate_id' => "candidate\u200Bid")
    bidi = proposal.merge('candidate_id' => "candidate\u202Eid")

    [ deep, { 'entries' => Array.new(25, {}) }, invalid_encoding, control, zero_width, bidi ].each do |value|
      expect {
        expect(described_class.from_snapshot(value, ocr_snapshot: snapshot)).to be_nil
      }.not_to raise_error
    end
  end
end
