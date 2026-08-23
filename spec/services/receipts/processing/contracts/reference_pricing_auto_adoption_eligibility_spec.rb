require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ReferencePricingAutoAdoptionEligibility do
  def destination_ocr_result
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def valid_snapshot
    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(destination_ocr_result)
  end

  def valid_proposal(snapshot = valid_snapshot)
    snapshot.dig('adoption_proposals', 'reference_pricing')
  end

  def valid_destination(proposal = valid_proposal)
    {
      'candidate_identity' => proposal.fetch('candidate_id'),
      'destination_identity' => proposal.dig('destination', 'identity')
    }
  end

  def call_policy(
    snapshot: valid_snapshot,
    proposals: nil,
    destinations: nil,
    authority_state: 'absent',
    expected_receipt_lock_version: 4,
    current_receipt_lock_version: 4,
    projected_amount_limit: 999_999_999
  )
    proposal = valid_proposal(snapshot)
    described_class.call(
      ocr_snapshot: snapshot,
      proposals: proposals || [ proposal ],
      destinations: destinations || [ valid_destination(proposal) ],
      authority_state:,
      expected_receipt_lock_version:,
      current_receipt_lock_version:,
      projected_amount_limit:
    )
  end

  def counted_application_queries
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name].in?(%w[SCHEMA CACHE])
      next if payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    queries
  end

  it 'strict gross proposalと一意なdestinationだけを入力非破壊・DB非依存でeligibleにする' do
    snapshot = valid_snapshot
    proposal = valid_proposal(snapshot)
    destination = valid_destination(proposal)
    source = Marshal.load(Marshal.dump([ snapshot, proposal, destination ]))
    result = nil

    queries = counted_application_queries do
      result = call_policy(
        snapshot:,
        proposals: [ proposal ],
        destinations: [ destination ]
      )
    end

    aggregate_failures do
      expect(result).to be_eligible
      expect(result.reason).to eq('eligible')
      expect(result.candidate_identity).to eq(proposal.fetch('candidate_id'))
      expect(result.destination_identity).to eq(proposal.dig('destination', 'identity'))
      expect(result.contract_version).to eq('reference_pricing_auto_adoption_eligibility_v1')
      expect(queries).to be_empty
      expect([ snapshot, proposal, destination ]).to eq(source)
    end
  end

  it 'proposalまたはdestinationが0件・複数ならfail-closedにする' do
    proposal = valid_proposal
    destination = valid_destination(proposal)

    aggregate_failures do
      expect(call_policy(proposals: []).reason).to eq('proposal_count_invalid')
      expect(call_policy(proposals: [ proposal, proposal.deep_dup ]).reason).to eq('proposal_count_invalid')
      expect(call_policy(destinations: []).reason).to eq('destination_count_invalid')
      expect(call_policy(destinations: [ destination, destination.deep_dup ]).reason).to eq(
        'destination_count_invalid'
      )
    end
  end

  it 'candidate countが0件・複数またはvalidでなくなったsnapshotを拒否する' do
    base = valid_snapshot
    candidate = base.dig('candidates', 'reference_pricing_candidates', 0)
    snapshots = [
      base.deep_merge(
        'candidates' => { 'reference_pricing_candidates' => [] },
        'candidate_counts' => {
          'reference_pricing_candidates' => { 'actual_count' => 0, 'snapshot_count' => 0 }
        }
      ),
      base.deep_merge(
        'candidates' => { 'reference_pricing_candidates' => [ candidate, candidate.deep_dup ] },
        'candidate_counts' => {
          'reference_pricing_candidates' => { 'actual_count' => 2, 'snapshot_count' => 2 }
        }
      ),
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('validation_state' => 'ambiguous') ]
        }
      )
    ]

    snapshots.each do |snapshot|
      expect(call_policy(snapshot:, proposals: [ valid_proposal(base) ]).reason).to eq('proposal_invalid')
    end
  end

  it 'version・source・identity・checksum・exact sourceの改変を拒否する' do
    snapshot = valid_snapshot
    proposal = valid_proposal(snapshot)
    mutations = [
      proposal.merge('schema_version' => 'reference_pricing_adoption_proposal_v2'),
      proposal.merge('source_kind' => 'azure_item'),
      proposal.merge('provider_model_id' => 'unknown'),
      proposal.merge('provider_api_version' => 'unknown'),
      proposal.merge('string_index_type' => 'unicodeCodePoint'),
      proposal.merge('candidate_id' => 'azure_line_group_p0_l8_l9_reference_pricing'),
      proposal.merge('integrity_checksum' => '0' * 64),
      proposal.deep_merge('destination' => { 'identity' => 'mismatched' }),
      proposal.deep_merge('reference_price' => { 'amount' => nil }),
      proposal.deep_merge('reference_price' => { 'amount' => '1.0' }),
      proposal.deep_merge('reference_price' => { 'amount' => '0.0000001' }),
      proposal.deep_merge('reference_price' => { 'amount' => '1000000000000' }),
      proposal.deep_merge('reference_quantity' => { 'unit_code' => 'unknown' }),
      proposal.deep_merge('purchased_quantity' => { 'unit_code' => 'gram' }),
      proposal.merge('reference_price_tax_inclusion' => 'net'),
      proposal.deep_merge('corroboration' => { 'state' => 'mismatched' })
    ]

    mutations.each do |mutation|
      expect(call_policy(snapshot:, proposals: [ mutation ]).reason).to eq('proposal_invalid')
    end
  end

  it 'candidate/destination linkageまたはReceipt versionが変わると拒否する' do
    proposal = valid_proposal
    destination = valid_destination(proposal)

    aggregate_failures do
      expect(
        call_policy(destinations: [ destination.merge('candidate_identity' => 'mismatched') ]).reason
      ).to eq('destination_identity_mismatch')
      expect(
        call_policy(destinations: [ destination.merge('destination_identity' => 'mismatched') ]).reason
      ).to eq('destination_identity_mismatch')
      expect(call_policy(current_receipt_lock_version: 5).reason).to eq('receipt_version_mismatch')
      expect(call_policy(expected_receipt_lock_version: nil).reason).to eq('receipt_version_mismatch')
    end
  end

  it 'package・discount・adjacent・multiple expression・printed item total・netを拒否する' do
    base = valid_snapshot
    candidate = base.dig('candidates', 'reference_pricing_candidates', 0)
    snapshots = [
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('rejection_reasons' => [ 'package_conflict' ]) ]
        }
      ),
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('rejection_reasons' => [ 'discount_conflict' ]) ]
        }
      ),
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('rejection_reasons' => [ 'adjacent_conflict' ]) ]
        }
      ),
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('rejection_reasons' => [ 'multiple_expression' ]) ]
        }
      ),
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('printed_line_total' => '300') ]
        }
      ),
      base.deep_merge(
        'candidates' => {
          'reference_pricing_candidates' => [ candidate.merge('reference_price_tax_inclusion' => 'net') ]
        }
      )
    ]

    snapshots.each do |snapshot|
      expect(call_policy(snapshot:, proposals: [ valid_proposal(base) ]).reason).to eq('proposal_invalid')
    end
  end

  it 'authority・partial metadata・projection上限超過を個別理由で拒否する' do
    aggregate_failures do
      expect(call_policy(authority_state: 'existing').reason).to eq('existing_authority')
      expect(call_policy(authority_state: 'partial').reason).to eq('partial_source_metadata')
      expect(call_policy(authority_state: 'unknown').reason).to eq('authority_state_invalid')
      expect(call_policy(projected_amount_limit: 299).reason).to eq('projection_out_of_bounds')
      expect(call_policy(projected_amount_limit: nil).reason).to eq('projection_limit_invalid')
    end
  end

  it 'DB・provider・AI呼出しやauthority writeを行わない' do
    allow(ReceiptOcrService).to receive(:call)
    allow(ReceiptAiEnrichmentService).to receive(:call)
    allow(ReceiptItem).to receive(:create!).and_call_original

    expect {
      result = call_policy
      expect(result).to be_eligible
    }.not_to change(ReceiptItem, :count)

    aggregate_failures do
      expect(ReceiptOcrService).not_to have_received(:call)
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      expect(ReceiptItem).not_to have_received(:create!)
    end
  end
end
