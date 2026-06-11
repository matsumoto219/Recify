require 'rails_helper'

RSpec.describe Amounts::CandidateSnapshot do
  def candidate(id, score:, rejected: false)
    Amounts::Candidate.new(
      candidate_id: id,
      basis: id,
      subtotal: score,
      tax: 0,
      purchase_total: score,
      final_payment_total: score,
      score: score,
      hard_reject_reasons: rejected ? [ :test_reject ] : []
    )
  end

  def snapshot_candidate_ids(snapshot)
    snapshot[:candidates].map { |entry| entry[:candidate_id] }
  end

  let(:selected) { candidate('selected', score: 10) }
  let(:candidates) do
    [
      candidate('accepted-low', score: 1),
      selected,
      candidate('accepted-mid', score: 5),
      candidate('accepted-high', score: 20),
      candidate('rejected-low', score: 0, rejected: true),
      candidate('rejected-high', score: 30, rejected: true)
    ]
  end

  it 'default 3でselectedと上位候補を3件だけ保存する' do
    snapshot = described_class.call(selected: selected, candidates: candidates)

    aggregate_failures do
      expect(snapshot[:selected_candidate_id]).to eq('selected')
      expect(snapshot.dig(:selected_candidate, :candidate_id)).to eq('selected')
      expect(snapshot_candidate_ids(snapshot)).to eq(%w[selected accepted-low accepted-mid])
    end
  end

  it '設定値1ならcandidate一覧はwinnerのみ保存する' do
    create(
      :system_setting,
      key: Amounts::CandidateSnapshot::SETTING_KEY,
      value: SystemSettings.stored_value(1)
    )

    snapshot = described_class.call(selected: selected, candidates: candidates)

    aggregate_failures do
      expect(snapshot.dig(:selected_candidate, :candidate_id)).to eq('selected')
      expect(snapshot_candidate_ids(snapshot)).to eq(%w[selected])
    end
  end

  it '設定値5なら5件保存する' do
    create(
      :system_setting,
      key: Amounts::CandidateSnapshot::SETTING_KEY,
      value: SystemSettings.stored_value(5)
    )

    snapshot = described_class.call(selected: selected, candidates: candidates)

    expect(snapshot_candidate_ids(snapshot)).to eq(%w[selected accepted-low accepted-mid accepted-high rejected-low])
  end

  it '設定値がmaxを超えても20件までしか保存しない' do
    allow(SystemSettings).to receive(:limit_for).and_call_original
    allow(SystemSettings).to receive(:limit_for).with(Amounts::CandidateSnapshot::SETTING_KEY).and_return(25)
    many_candidates = Array.new(25) { |index| candidate("candidate-#{index}", score: index) }
    selected = many_candidates.last

    snapshot = described_class.call(selected: selected, candidates: many_candidates)

    aggregate_failures do
      expect(snapshot.dig(:selected_candidate, :candidate_id)).to eq('candidate-24')
      expect(snapshot[:candidates].size).to eq(20)
      expect(snapshot_candidate_ids(snapshot).first).to eq('candidate-24')
    end
  end

  it '設定値が0や負数でもsnapshot未保存にはせずwinnerのみ保存する' do
    allow(SystemSettings).to receive(:limit_for).and_call_original

    [ 0, -5 ].each do |count|
      allow(SystemSettings).to receive(:limit_for).with(Amounts::CandidateSnapshot::SETTING_KEY).and_return(count)

      snapshot = described_class.call(selected: selected, candidates: candidates)

      aggregate_failures "count=#{count}" do
        expect(snapshot.dig(:selected_candidate, :candidate_id)).to eq('selected')
        expect(snapshot_candidate_ids(snapshot)).to eq(%w[selected])
      end
    end
  end
end
