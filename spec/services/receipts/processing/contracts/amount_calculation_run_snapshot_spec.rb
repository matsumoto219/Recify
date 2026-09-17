require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::AmountCalculationRunSnapshot do
  let(:limits) { { 'max_bytes' => 131_072, 'computed_items' => 100, 'evidence' => 200, 'candidates' => 3 } }
  let(:item) { { price: 100, quantity: BigDecimal('1.25'), quantity_unit_code: 'gram', line_total: 125 } }
  let(:evidence) { { source: 'receipt_items', index: 0, amount: 125, formula: 'items_as_tax_included' } }
  let(:candidate) do
    {
      candidate_id: 'items_as_tax_included/floor/per_item', basis: 'items_as_tax_included',
      subtotal: 114, tax: 11, purchase_total: 125, final_payment_total: 125,
      purchase_adjustment_total: 0, payment_adjustment_total: 0, score: 0,
      score_breakdown: { receipt_total_delta: 0 }, warnings: [], hard_reject_reasons: [],
      rounding_mode: 'floor', rounding_scope: 'per_item', computed_items: [ item ], evidence: [ evidence ]
    }
  end
  let(:amount_result) do
    {
      context: :analysis, rounding_mode: { tax: :floor, discount: :floor },
      computed: { total: 125, subtotal: 114, tax: 11 }, resolved: { total: 125, subtotal: 114, tax: 11 },
      calculation_profile: { receipt_tax_basis: 'total_includes_tax' }, calculation_profile_score: 0,
      needs_review: false, review_reasons: [], mismatch_codes: [], blocking_mismatch_codes: [], warning_mismatch_codes: [],
      selected_candidate_status: 'accepted', safe_to_auto_complete: true,
      amount_engine: {
        schema_version: 1, selected_candidate_id: candidate[:candidate_id], selected_basis: candidate[:basis],
        selected_candidate_status: 'accepted', no_safe_candidate: false,
        selected_candidate: candidate, candidates: [ candidate ]
      }
    }
  end
  let(:saved_profile) do
    {
      'schema_version' => 1, 'context' => 'analysis', 'profile' => { 'receipt_tax_basis' => 'total_includes_tax' },
      'rounding_mode' => { 'tax' => 'floor', 'discount' => 'floor' },
      'computed' => { 'total_amount' => 125 }, 'resolved' => { 'total_amount' => 125 },
      'selected_candidate_status' => 'accepted', 'safe_to_auto_complete' => true
    }
  end
  let(:receipt_summary) { { status: 'review_needed', total_amount: 125, subtotal_amount: 114, tax_amount: 11 } }

  def build(**overrides)
    described_class.build(**{
      amount_result: amount_result, saved_profile: saved_profile, receipt_summary: receipt_summary, limits: limits
    }.merge(overrides))
  end

  it '最終engine・保存profile・Receipt状態を分離し、入力非破壊でexact round-tripする' do
    original = Marshal.dump([ amount_result, saved_profile, receipt_summary, limits ])
    snapshot = build

    aggregate_failures do
      expect(snapshot.fetch('schema_version')).to eq('amount_calculation_run_snapshot_v1')
      expect(snapshot.fetch('state')).to eq('available')
      expect(snapshot.dig('engine', 'review', 'needs_review')).to be(false)
      expect(snapshot.dig('engine', 'review', 'warning_classification')).to eq('unrecorded')
      expect(snapshot.dig('receipt_summary', 'status')).to eq('review_needed')
      expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'computed_items', 0, 'quantity')).to eq('1.25')
      expect(snapshot.dig('engine', 'amount_engine', 'candidates', 0)).to eq(
        'candidate_id' => candidate[:candidate_id], 'selected_candidate_ref' => true
      )
      expect(described_class.read(JSON.parse(JSON.generate(snapshot)))).to eq(snapshot)
      expect(Marshal.dump([ amount_result, saved_profile, receipt_summary, limits ])).to eq(original)
    end
  end

  it '同じ候補詳細の参照再利用を情報省略として扱わない' do
    snapshot = build

    expect(snapshot.fetch('omissions')).to all(include('omitted_count' => 0))
    expect(snapshot.fetch('state')).to eq('available')
  end

  it 'warning別のclassificationやReceipt statusからAmount review判定を推測しない' do
    result = amount_result.merge(needs_review: true, review_reasons: [ 'purchase_adjustment_tax_allocation_uncertain' ],
      warning_mismatch_codes: [ 'ADJUSTMENT_TAX_RATE_MISSING' ])
    snapshot = build(amount_result: result)

    expect(snapshot.dig('engine', 'review')).to include(
      'needs_review' => true, 'review_reasons' => [ 'purchase_adjustment_tax_allocation_uncertain' ],
      'warning_mismatch_codes' => [ 'ADJUSTMENT_TAX_RATE_MISSING' ], 'warning_classification' => 'unrecorded'
    )
  end

  it '128 byteのexact numberを切断・丸めず保存する' do
    exact = "123456789012345.#{'1' * 112}"
    snapshot = build(amount_result: amount_result.deep_merge(resolved: { tax_rate: exact }))

    expect(exact.bytesize).to eq(128)
    expect(snapshot.dig('engine', 'resolved', 'tax_rate')).to eq(exact)
    expect(described_class.read(snapshot)).to eq(snapshot)
  end

  it 'finite Rationalだけをexact decimalへ変換する' do
    snapshot = build(amount_result: amount_result.deep_merge(resolved: { tax_rate: Rational(1, 8) }))

    expect(snapshot.dig('engine', 'resolved', 'tax_rate')).to eq('0.125')
    expect(build(amount_result: amount_result.deep_merge(resolved: { tax_rate: Rational(1, 3) }))).to include(
      'state' => 'unavailable', 'reason' => 'invalid_diagnostics'
    )
  end

  it '未知・不正な必須診断を空の正常snapshotにしない' do
    [ nil, {}, [], amount_result.merge(context: 'secret'), amount_result.deep_merge(amount_engine: { schema_version: 2 }),
      { context: :analysis, rounding_mode: {}, computed: {}, resolved: {} },
      amount_result.except(:needs_review), amount_result.except(:review_reasons), amount_result.except(:amount_engine),
      amount_result.deep_merge(resolved: { total: Float::NAN }),
      amount_result.deep_merge(resolved: { total: '1' * 129 }),
      amount_result.deep_merge(resolved: { total: '01' }),
      amount_result.deep_merge(resolved: { total: "1\u0000" }) ].each do |input|
      snapshot = build(amount_result: input)
      expect(snapshot.fetch('state')).to eq('unavailable')
      expect(described_class.read(snapshot)).to eq(snapshot)
    end
  end

  it 'safe candidateなしとmanual contextをmissing診断と混同しない' do
    result = amount_result.merge(context: :manual, needs_review: true, review_reasons: [ 'insufficient_data' ],
      amount_engine: { schema_version: 1, no_safe_candidate: true, candidates: [] })
    snapshot = build(amount_result: result)

    expect(snapshot.fetch('state')).to eq('available')
    expect(snapshot.dig('engine', 'context')).to eq('manual')
    expect(snapshot.dig('engine', 'amount_engine')).to eq('schema_version' => 1, 'no_safe_candidate' => true, 'candidates' => [])
    expect(described_class.read(snapshot)).to eq(snapshot)
  end

  it '上限metadata欠損は現在設定を読み直さず利用不可とする' do
    expect(SystemSettings).not_to receive(:limits_for)
    expect(SystemSettings).not_to receive(:limit_for)

    expect(build(limits: nil)).to include('state' => 'unavailable', 'reason' => 'limits_missing')
  end

  it 'unknown raw keysとformula文字列を保存しない' do
    contaminated = amount_result.merge(prompt: 'PRIVATE_PROMPT', merchant: 'PRIVATE_MERCHANT')
    contaminated[:amount_engine] = amount_result[:amount_engine].deep_dup
    contaminated[:amount_engine][:selected_candidate][:computed_items][0][:name] = 'PRIVATE_PRODUCT'
    snapshot = build(amount_result: contaminated, saved_profile: saved_profile.merge('raw' => 'PRIVATE_RAW'))

    expect(JSON.generate(snapshot)).not_to include('PRIVATE_', 'prompt', 'merchant')
    invalid = amount_result.deep_dup
    invalid[:amount_engine][:selected_candidate][:evidence][0][:formula] = 'PRIVATE_FORMULA'
    expect(build(amount_result: invalid).fetch('state')).to eq('partial')
    expect(JSON.generate(build(amount_result: invalid))).not_to include('PRIVATE_FORMULA')
  end

  it '件数上限を合算し、元件数と固定順の省略件数を記録する' do
    other = candidate.deep_merge(candidate_id: 'items_as_tax_included/round/per_item', rounding_mode: 'round')
    selected = candidate.merge(computed_items: Array.new(25) { item }, evidence: Array.new(45) { evidence })
    other[:evidence] = Array.new(10) { evidence }
    result = amount_result.deep_merge(amount_engine: { selected_candidate: selected, candidates: [ selected, other ] })
    snapshot = build(amount_result: result, limits: limits.merge('computed_items' => 20, 'evidence' => 40))

    aggregate_failures do
      expect(snapshot.fetch('state')).to eq('partial')
      expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'computed_items').size).to eq(20)
      expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'evidence').size).to eq(39)
      expect(snapshot.dig('engine', 'amount_engine', 'candidates', 1, 'evidence').size).to eq(1)
      expect(snapshot.fetch('omissions')).to include(
        include('path' => 'selected.computed_items', 'source_count' => 25, 'stored_count' => 20, 'omitted_count' => 5),
        include('path' => 'selected.evidence', 'source_count' => 45, 'stored_count' => 39, 'omitted_count' => 6)
      )
      expect(described_class.read(snapshot)).to eq(snapshot)
    end
  end

  it 'readerは未知version/key・型違い・件数改変を拒否し現在設定へ依存しない' do
    snapshot = build
    expect(SystemSettings).not_to receive(:limit_for)
    [ nil, [], {}, snapshot.merge('schema_version' => 'unknown'), snapshot.merge('secret' => 'value'),
      snapshot.deep_merge('limits' => { 'max_bytes' => 64_000 }),
      snapshot.deep_merge('engine' => { 'review' => { 'needs_review' => 'false' } }),
      snapshot.merge('omissions' => [ { 'path' => 'selected.evidence', 'source_count' => 1, 'stored_count' => 2, 'omitted_count' => -1, 'reasons' => [] } ]) ].each do |input|
      expect(described_class.read(input)).to be_nil
    end
  end

  it 'invalid detailの省略は元位置と件数を保持し、byte/count省略と区別する' do
    selected = candidate.merge(computed_items: [ { price: 'PRIVATE_VALUE' }, item ])
    result = amount_result.merge(amount_engine: amount_result[:amount_engine].merge(selected_candidate: selected, candidates: [ selected ]))
    snapshot = build(amount_result: result)

    expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'computed_items')).to eq(
      [ { 'price' => 100, 'quantity' => '1.25', 'quantity_unit_code' => 'gram', 'line_total' => 125, 'snapshot_index' => 1 } ]
    )
    expect(snapshot.fetch('omissions')).to include(
      include('path' => 'selected.computed_items', 'source_count' => 2, 'stored_count' => 1,
        'omitted_count' => 1, 'reasons' => [ 'invalid_value' ])
    )
    expect(described_class.read(snapshot)).to eq(snapshot)
    modified = snapshot.deep_dup
    modified['engine']['amount_engine']['selected_candidate']['computed_items'][0]['snapshot_index'] = 2
    expect(described_class.read(modified)).to be_nil
  end

  it '候補件数を固定上限へ省略してもselected summaryを置き換えない' do
    other = candidate.merge(candidate_id: 'items_as_tax_included/ceil/per_item', score: 200)
    result = amount_result.merge(amount_engine: amount_result[:amount_engine].merge(candidates: [ candidate, other ]))
    snapshot = build(amount_result: result, limits: limits.merge('candidates' => 1))

    expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'score')).to eq(0)
    expect(snapshot.dig('engine', 'amount_engine', 'candidates').size).to eq(1)
    expect(snapshot.fetch('omissions')).to include(
      include('path' => 'candidates', 'source_count' => 2, 'stored_count' => 1, 'omitted_count' => 1, 'reasons' => [ 'count_limit' ])
    )
    expect(described_class.read(snapshot)).to eq(snapshot)
  end

  it '重複candidate identityとfractional penaltyを不正診断として拒否する' do
    duplicate = amount_result.deep_merge(amount_engine: { candidates: [ candidate, candidate ] })
    decimal_score = amount_result.deep_merge(amount_engine: { selected_candidate: candidate.merge(score: '0.1') })

    [ duplicate, decimal_score ].each do |result|
      expect(build(amount_result: result)).to include('state' => 'unavailable', 'reason' => 'invalid_diagnostics')
    end
  end

  it 'engineと保存profileの税率別basis根拠も合計evidence上限へ含める' do
    assignment = { tax_rate: '0.1', basis: 'tax_excluded', net_amount: 100, tax_amount: 10, gross_amount: 110 }
    result = amount_result.merge(calculation_profile: amount_result[:calculation_profile].merge(item_amount_basis_assignments: Array.new(45) { assignment }))
    profile = saved_profile.deep_merge('profile' => { 'item_amount_basis_assignments' => Array.new(45) { assignment } })
    snapshot = build(amount_result: result, saved_profile: profile, limits: limits.merge('evidence' => 40))

    aggregate_failures do
      expect(snapshot.fetch('state')).to eq('partial')
      expect(snapshot.dig('engine', 'profile', 'item_amount_basis_assignments').size).to eq(38)
      expect(snapshot.dig('saved_profile', 'profile', 'item_amount_basis_assignments').size).to eq(1)
      expect(snapshot.fetch('omissions')).to include(
        include('path' => 'engine.profile.item_amount_basis_assignments', 'source_count' => 45, 'stored_count' => 38, 'omitted_count' => 7),
        include('path' => 'saved_profile.profile.item_amount_basis_assignments', 'source_count' => 45, 'stored_count' => 1, 'omitted_count' => 44)
      )
      expect(described_class.read(snapshot)).to eq(snapshot)
    end
  end

  it '正常最大のmandatory診断全体が128KiBに収まり比較根拠を保つ' do
    exact = "123456789012345.#{'1' * 112}"
    # Candidate construction and scoring emit integer yen/penalties; rate,
    # quantity and other exact diagnostic tokens retain the 128-byte boundary.
    amounts = %i[subtotal tax purchase_total final_payment_total purchase_adjustment_total payment_adjustment_total payment_amount_sum score].index_with { 999_999_999_999_999 }
    item_values = %i[price quantity original_line_total line_total discount_amount discount_rate tax_rate].index_with { exact }
    evidence_values = %i[rate amount printed_amount net_amount gross_amount tax_amount target_net_amount target_tax_amount target_gross_amount purchase_total final_payment_total payment_amount_sum payment_delta tax_rate].index_with { exact }
    detailed_evidence = evidence.merge(evidence_values).merge(
      index: 1_000_000, basis: 'non_taxable', printed_amount_basis: 'intermediate',
      payment_amount_mismatch_suppressed: true, suppressed_reason: 'tendered_like_overpayment',
      effect: 'unknown_adjustment', kind: 'late_night_charge', sign: 'surcharge', tax_rate_source: 'inherited_single_rate'
    )
    profile = {
      tax_rounding_mode: 'floor', discount_rounding_mode: 'floor', receipt_tax_basis: 'tax_added_to_subtotal',
      item_amount_basis: 'mixed_by_tax_rate_group', tax_detail_amount_basis: 'unknown',
      item_amount_basis_assignments: Array.new(100) do
        { tax_rate: exact, basis: 'tax_excluded', net_amount: exact, tax_amount: exact, gross_amount: exact }
      end
    }
    candidates = described_class::CANDIDATE_IDS.first(20).map do |id|
      candidate.merge(amounts).merge(candidate_id: id,
        score_breakdown: described_class::SCORE_KEYS.index_with { 999_999_999_999_999 },
        warnings: described_class::REASONS, hard_reject_reasons: described_class::REASONS,
        computed_items: Array.new(100) { item.merge(item_values) },
        evidence: Array.new(100) { detailed_evidence })
    end
    totals = (described_class::TOTAL_KEYS - [ 'tax_detail_amount_basis' ]).index_with { exact }
    result = amount_result.merge(
      computed: totals, resolved: totals, calculation_profile_score: exact, calculation_profile: profile,
      review_reasons: described_class::REASONS, warnings: described_class::REASONS,
      mismatch_codes: described_class::REASONS.map(&:upcase), blocking_mismatch_codes: described_class::REASONS.map(&:upcase),
      warning_mismatch_codes: described_class::REASONS.map(&:upcase),
      amount_engine: amount_result[:amount_engine].merge(
        selected_candidate_id: candidates.first[:candidate_id], selected_candidate: candidates.first, candidates: candidates
      )
    )
    persisted_profile = saved_profile.merge(
      'computed' => totals, 'resolved' => totals, 'score' => exact, 'profile' => profile,
      'rounding_mode' => { 'tax' => 'floor', 'discount' => 'floor' },
      'warnings' => described_class::REASONS, 'mismatch_codes' => described_class::REASONS.map(&:upcase),
      'blocking_mismatch_codes' => described_class::REASONS.map(&:upcase), 'warning_mismatch_codes' => described_class::REASONS.map(&:upcase)
    )
    snapshot = build(amount_result: result, limits: limits.merge('candidates' => 20), saved_profile: persisted_profile)

    aggregate_failures do
      expect(snapshot.fetch('state')).not_to eq('unavailable')
      expect(JSON.generate(snapshot).bytesize).to be <= 131_072
      expect(snapshot.dig('engine', 'amount_engine', 'candidates').size).to eq(20)
      expect(snapshot.dig('engine', 'amount_engine', 'candidates').drop(1)).to all(satisfy { |entry| entry.fetch('evidence').any? })
      expect(described_class.read(snapshot)).to eq(snapshot)
    end
  end

  it 'readerは巨大・循環・過深・不正encodingをraw dumpなしで拒否する' do
    cycle = []
    cycle << cycle
    snapshot = build
    huge = snapshot.deep_merge('engine' => { 'resolved' => { 'total_amount' => '9' * 1_048_577 } })
    encoded = snapshot.deep_merge('engine' => { 'context' => "\xFF".b })

    [ huge, encoded, cycle, { 'nested' => cycle }, snapshot.deep_merge('engine' => { 'computed' => { 'secret' => 'PRIVATE_VALUE' } }) ].each do |input|
      expect { expect(described_class.read(input)).to be_nil }.not_to raise_error
    end
  end

  it '必須の計算合計とReceipt状態が欠落した履歴を正常扱いしない' do
    snapshot = build
    [ snapshot.merge('engine' => snapshot.fetch('engine').merge('computed' => {})),
      snapshot.merge('engine' => snapshot.fetch('engine').merge('resolved' => {})),
      snapshot.merge('receipt_summary' => {}) ].each do |input|
      expect(described_class.read(input)).to be_nil
    end

    expect(build(receipt_summary: {})).to include('state' => 'unavailable')
    expect(build(amount_result: amount_result.merge(computed: { total: nil }))).to include('state' => 'unavailable')
  end

  it '正常最大の設定でも完成schema全体をbyte予算内で構成する' do
    selected = candidate.merge(computed_items: Array.new(10_000) { item }, evidence: Array.new(10_000) { evidence })
    result = amount_result.merge(amount_engine: amount_result[:amount_engine].merge(selected_candidate: selected, candidates: [ selected ]))
    snapshot = build(amount_result: result, limits: limits.merge('max_bytes' => 1_048_576, 'computed_items' => 10_000, 'evidence' => 10_000))

    aggregate_failures do
      expect(snapshot.fetch('state')).to eq('partial')
      expect(JSON.generate(snapshot).bytesize).to be <= 1_048_576
      expect(snapshot.fetch('omissions')).to include(include('reasons' => include('byte_limit')))
      expect(described_class.read(snapshot)).to eq(snapshot)
    end
  end

  it '必須review理由と丸め方式の部分欠損を正常な履歴にしない' do
    snapshot = build
    missing_review = snapshot.deep_dup
    missing_review.fetch('engine').fetch('review').delete('review_reasons')
    missing_rounding = snapshot.deep_dup
    missing_rounding.fetch('engine')['rounding_mode'] = { 'tax' => 'floor' }

    expect(described_class.read(missing_review)).to be_nil
    expect(described_class.read(missing_rounding)).to be_nil
    expect(build(amount_result: amount_result.merge(rounding_mode: {}))).to include('state' => 'unavailable')
  end

  it '候補の判定・score・理由が欠落した部分診断を拒否する' do
    %w[basis subtotal tax purchase_total score score_breakdown warnings hard_reject_reasons rounding_mode rounding_scope].each do |key|
      snapshot = build
      snapshot.dig('engine', 'amount_engine', 'selected_candidate').delete(key)
      expect(described_class.read(snapshot)).to be_nil
      invalid = amount_result.deep_dup
      invalid[:amount_engine][:selected_candidate].delete(key.to_sym)
      expect(build(amount_result: invalid)).to include('state' => 'unavailable')
    end
    %w[no_safe_candidate selected_basis selected_candidate_status].each do |key|
      snapshot = build
      snapshot.dig('engine', 'amount_engine').delete(key)
      expect(described_class.read(snapshot)).to be_nil
    end
  end

  it '候補のない結果に元からないreview理由を補完・必須化しない' do
    result = amount_result.except(:review_reasons).merge(
      amount_engine: { schema_version: 1, no_safe_candidate: true, candidates: [] }
    )
    snapshot = build(amount_result: result)

    expect(snapshot.fetch('state')).to eq('available')
    expect(snapshot.fetch('engine').fetch('review')).not_to have_key('review_reasons')
    expect(described_class.read(snapshot)).to eq(snapshot)
  end

  it '保存profileの必須投影が欠損した履歴を拒否する' do
    %w[context rounding_mode computed resolved].each do |key|
      snapshot = build
      snapshot.fetch('saved_profile').delete(key)
      expect(described_class.read(snapshot)).to be_nil
      expect(build(saved_profile: saved_profile.except(key))).to include('state' => 'unavailable')
    end
  end
end
