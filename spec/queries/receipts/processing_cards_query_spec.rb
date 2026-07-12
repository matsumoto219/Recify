require 'rails_helper'

RSpec.describe Receipts::ProcessingCardsQuery do
  let(:user) { create(:user) }

  def call_query(public_ids:, state_revisions: [])
    described_class.call(user:, public_ids:, state_revisions:)
  end

  it 'keeps request order and revision alignment while returning only the current user active receipts' do
    receipt = create(:receipt, :processing, :with_image, user:)
    active_run = create(:receipt_analysis_run, :running, receipt:)
    other_receipt = create(:receipt, :processing, :with_image, user: create(:user))
    quarantined_receipt = create(:receipt, :processing, :quarantined, :with_image, user:)

    result = call_query(
      public_ids: [
        'invalid',
        receipt.public_id,
        receipt.public_id,
        other_receipt.public_id,
        quarantined_receipt.public_id
      ],
      state_revisions: %w[invalid current duplicate other quarantined]
    )

    aggregate_failures do
      expect(result.entries.map(&:public_id)).to eq(
        [ receipt.public_id, other_receipt.public_id, quarantined_receipt.public_id ]
      )
      expect(result.entries.map(&:requested_state_revision)).to eq(%w[current other quarantined])
      expect(result.entries.first.receipt).to eq(receipt)
      expect(result.entries.first.analysis_run).to eq(active_run)
      expect(result.entries.drop(1).map(&:receipt)).to eq([ nil, nil ])
      expect(result.entries.drop(1).map(&:analysis_run)).to eq([ nil, nil ])
    end
  end

  it 'ignores terminal runs when resolving the active processing run' do
    receipt = create(:receipt, :processing, :with_image, user:)
    create(:receipt_analysis_run, :failed, receipt:, created_at: 1.minute.ago)

    result = call_query(public_ids: [ receipt.public_id ])

    expect(result.entries.first.analysis_run).to be_nil
  end

  it 'limits normalized unique public ids to the first one hundred valid requests' do
    public_ids = 101.times.map { |index| format('rcpt_%016d', index) }
    revisions = 101.times.map { |index| "revision-#{index}" }

    result = call_query(public_ids:, state_revisions: revisions)

    aggregate_failures do
      expect(result.entries.size).to eq(100)
      expect(result.entries.first.public_id).to eq(public_ids.first)
      expect(result.entries.first.requested_state_revision).to eq(revisions.first)
      expect(result.entries.last.public_id).to eq(public_ids[99])
      expect(result.entries.last.requested_state_revision).to eq(revisions[99])
    end
  end

  it 'returns an immutable empty result for missing request arrays' do
    result = call_query(public_ids: nil, state_revisions: nil)

    aggregate_failures do
      expect(result).to be_frozen
      expect(result.entries).to eq([])
      expect(result.entries).to be_frozen
      expect { result.entries << :unexpected }.to raise_error(FrozenError)
    end
  end
end
