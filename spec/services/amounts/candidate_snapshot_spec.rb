require 'rails_helper'

RSpec.describe Amounts::CandidateSnapshot do
  def candidate(id, score:, rejected: false, **attributes)
    Amounts::Candidate.new(
      candidate_id: id,
      basis: id,
      subtotal: score,
      tax: 0,
      purchase_total: score,
      final_payment_total: score,
      score: score,
      hard_reject_reasons: rejected ? [ :test_reject ] : [],
      **attributes
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
      expect(snapshot[:schema_version]).to eq(1)
      expect(snapshot[:selected_candidate_id]).to eq('selected')
      expect(snapshot[:selected_candidate_status]).to eq('accepted')
      expect(snapshot[:no_safe_candidate]).to be(false)
      expect(snapshot.dig(:selected_candidate, :candidate_id)).to eq('selected')
      expect(snapshot_candidate_ids(snapshot)).to eq(%w[selected accepted-low accepted-mid])
    end
  end

  it '全candidateがrejectedの場合は安全な候補がないことをmetadataに残す' do
    rejected = candidate('rejected-selected', score: 1, rejected: true)
    snapshot = described_class.call(
      selected: rejected,
      candidates: [
        rejected,
        candidate('rejected-other', score: 2, rejected: true)
      ]
    )

    aggregate_failures do
      expect(snapshot[:selected_candidate_status]).to eq('rejected')
      expect(snapshot[:no_safe_candidate]).to be(true)
      expect(snapshot.dig(:selected_candidate, :hard_reject_reasons)).to include(:test_reject)
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

  it 'raw textやprovider metadataをsnapshotへ含めない' do
    leaky_candidate = candidate(
      'leaky',
      score: 100,
      score_breakdown: {
        receipt_total_delta: 0,
        raw_text: '保存しないOCR全文',
        provider_raw_response: { endpoint: 'https://example.invalid/ocr' },
        metadata: { source_text: '保存しないnested source text' }
      },
      evidence: [
        {
          source: 'receipt_payments',
          payment_amount_sum: 100,
          printed_amount: 820,
          printed_amount_basis: :gross_target,
          target_net_amount: 746,
          target_tax_amount: 74,
          target_gross_amount: 820,
          raw_text: '保存しないraw text',
          source_text: '保存しないsource text',
          description: '保存しないdescription',
          label: '保存しないlabel',
          raw_label: '保存しないraw label',
          payment_label: '保存しないpayment label',
          adjustment_label: '保存しないadjustment label',
          source_label: '保存しないsource label',
          endpoint: 'https://example.invalid/ocr',
          provider_raw_response: { body: '保存しないprovider body' },
          store_metadata: { name: '保存しない店舗metadata' },
          metadata: { raw_ocr_text: '保存しないnested raw OCR' }
        },
        {
          source: 'receipt_adjustment',
          effect: :purchase_adjustment,
          amount: 10,
          tax_rate: BigDecimal('0.10'),
          tax_rate_source: 'inherited_single_rate',
          source_text: '保存しない調整原文'
        }
      ],
      computed_items: [
        {
          price: 100,
          line_total: 100,
          raw_text: '保存しない商品raw text',
          source_text: '保存しない商品source text',
          description: '保存しない商品description',
          label: '保存しない商品label',
          metadata: { provider_raw_response: '保存しないnested provider' }
        }
      ]
    )

    snapshot = described_class.call(selected: leaky_candidate, candidates: [ leaky_candidate ])

    aggregate_failures do
      expect(snapshot[:schema_version]).to eq(1)
      expect(snapshot.dig(:selected_candidate, :score_breakdown)).to eq(receipt_total_delta: 0)
      expect(snapshot.dig(:selected_candidate, :evidence)).to eq([
        {
          source: 'receipt_payments',
          payment_amount_sum: 100,
          printed_amount: 820,
          printed_amount_basis: :gross_target,
          target_net_amount: 746,
          target_tax_amount: 74,
          target_gross_amount: 820
        },
        {
          source: 'receipt_adjustment',
          amount: 10,
          effect: :purchase_adjustment,
          tax_rate: BigDecimal('0.10'),
          tax_rate_source: 'inherited_single_rate'
        }
      ])
      expect(snapshot.dig(:selected_candidate, :computed_items)).to eq([
        { price: 100, line_total: 100 }
      ])
      expect(snapshot.to_json).not_to include(
        '保存しない',
        'raw text',
        'source text',
        'description',
        'label',
        'provider body',
        'example.invalid',
        '店舗metadata'
      )
    end
  end
end
