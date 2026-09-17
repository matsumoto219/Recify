require 'rails_helper'

RSpec.describe 'Amount calculation run snapshot persistence' do
  let(:snapshot_key) { 'amount_calculation_run_snapshot' }
  let(:limits_key) { 'amount_calculation_snapshot_limits_v1' }
  let(:receipt) do
    create(:receipt, :processing, :with_image, amount_calculation_profile: ReceiptAmountService.calculation_profile_snapshot(amount_result))
  end

  def amount_result(total: 770)
    ReceiptAmountService.call(
      receipt: { subtotal_amount: total, tax_amount: 0, total_amount: total, tax_rate: 0 },
      receipt_items: [ { price: total, quantity: 1, line_total: total, tax_rate: 0 } ],
      receipt_tax_details: [],
      context: :analysis
    )
  end

  def prepare_run(strategy: :ocr_only)
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    ocr_result = Ocr::ResponseParser.new(response: raw, provider: :fixture).call
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    if strategy == :ai_success
      Receipts::Processing.record_ai_normalized_result(
        run,
        {
          success: true,
          needs_review: false,
          receipt_attributes: {},
          receipt_items_attributes: []
        }
      )
    end
    decision = Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: strategy.to_s,
      error_code: { ai_fallback: 'ai_unavailable', fail_receipt: 'ocr_api_error' }[strategy],
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
    Receipts::Processing.record_finalize_decision(run, decision)
    run.reload
  end

  %i[ai_success ocr_only ai_fallback].each do |strategy|
    it "#{strategy}のitem mode再計算後の最終結果を保存する" do
      run = prepare_run(strategy:)
      results = []
      allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do |result|
          result[:calculation_profile_score] = results.size + 1
          results << result.deep_dup
        end
      end

      outcome = Receipts::Processing.run_finalize(run)
      snapshot = run.reload.final_result_summary.fetch(snapshot_key)

      aggregate_failures do
        expect(outcome.next_step).to eq(:done)
        expect(results.size).to eq(2)
        expect(snapshot.fetch('state')).to eq('partial')
        expect(snapshot.dig('engine', 'resolved')).to include(
          'total_amount' => results.last.dig(:resolved, :total),
          'subtotal_amount' => results.last.dig(:resolved, :subtotal),
          'tax_amount' => results.last.dig(:resolved, :tax)
        )
        expect(snapshot.dig('engine', 'score')).to eq(results.last.fetch(:calculation_profile_score))
        expect(snapshot.dig('engine', 'score')).not_to eq(results.first.fetch(:calculation_profile_score))
        expect(snapshot.dig('engine', 'review', 'needs_review')).to eq(results.last.fetch(:needs_review))
        expect(snapshot.dig('engine', 'review', 'warning_classification')).to eq('unrecorded')
        expect(snapshot.dig('receipt_summary', 'status')).to eq(receipt.reload.status)
        expect(snapshot.dig('receipt_summary', 'total_amount')).to eq(receipt.total_amount.to_i)
        expect(run.final_result_summary.fetch('schema_version')).to eq('receipt_analysis_run_final_result_v1')
        expect(Receipts::Processing::Contracts::AmountCalculationRunSnapshot.read(snapshot)).to eq(snapshot)
      end
    end
  end

  it 'engineの当時の警告と後処理後の保存profileとReceipt状態を区別する' do
    run = prepare_run
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap do |result|
        result[:warning_reasons] = [ 'tax_detail_rate_mismatch' ]
        result[:warning_mismatch_codes] = [ 'TAX_DETAIL_RATE_MISMATCH' ]
      end
    end

    Receipts::Processing.run_finalize(run)
    snapshot = run.reload.final_result_summary.fetch(snapshot_key)

    aggregate_failures do
      expect(snapshot.dig('engine', 'review', 'warning_reasons')).to include('tax_detail_rate_mismatch')
      expect(snapshot.dig('saved_profile', 'warnings')).not_to include('tax_detail_rate_mismatch')
      expect(snapshot.dig('saved_profile', 'warning_mismatch_codes')).to eq(receipt.reload.amount_calculation_profile.fetch('warning_mismatch_codes'))
      expect(snapshot.dig('engine', 'review', 'needs_review')).to be(false)
      expect(snapshot.dig('receipt_summary', 'status')).to eq('review_needed')
      expect(snapshot.dig('engine', 'review', 'warning_classification')).to eq('unrecorded')
    end
  end

  it 'Amount診断がない失敗結果は再計算せず利用不可として記録する' do
    run = prepare_run(strategy: :fail_receipt)
    expect(ReceiptAmountService).not_to receive(:call)

    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(run.reload.final_result_summary.fetch(snapshot_key)).to include('state' => 'unavailable', 'reason' => 'missing_diagnostics')
      expect(receipt.reload.status).to eq('failed')
    end
  end

  it '待機runの固定候補数を全Amount計算へ渡し現在設定を使わない' do
    setting = create(:system_setting, key: 'amount_engine.max_candidate_snapshot_count', value: SystemSettings.stored_value(1))
    run = prepare_run
    setting.update!(value: SystemSettings.stored_value(20))
    arguments = []
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      arguments << kwargs
      original.call(**kwargs)
    end

    Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(arguments).not_to be_empty
      expect(arguments).to all(include(snapshot_candidate_count: 1))
      expect(run.reload.final_result_summary.dig(snapshot_key, 'limits', 'candidates')).to eq(1)
      expect(run.final_result_summary.dig(snapshot_key, 'engine', 'amount_engine', 'candidates').size).to eq(1)
    end
  end

  it '後続編集と同一runの重複finalizeで履歴を上書きしない' do
    run = prepare_run
    Receipts::Processing.run_finalize(run)
    snapshot = run.reload.final_result_summary.fetch(snapshot_key).deep_dup
    expect(snapshot.fetch('state')).not_to eq('unavailable')
    receipt.reload.update!(total_amount: 999, amount_calculation_profile: { context: 'edit_save' })

    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(result.next_step).to eq(:skipped)
      expect(run.reload.final_result_summary.fetch(snapshot_key)).to eq(snapshot)
      expect(receipt.reload.total_amount).to eq(999)
    end
  end

  it 'terminal前のfinal summary再記録でも確定済みnested snapshotを維持する' do
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    first_result = amount_result
    Receipts::Processing.record_final_result(run, receipt:, amount_result: first_result)
    snapshot = run.reload.final_result_summary.fetch(snapshot_key).deep_dup

    Receipts::Processing.record_final_result(run, receipt:, amount_result: amount_result(total: 999))

    expect(run.reload.final_result_summary.fetch(snapshot_key)).to eq(snapshot)
  end

  it '一度利用不可と記録したsnapshotも後から正常結果へ差し替えない' do
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_final_result(run, receipt:)
    snapshot = run.reload.final_result_summary.fetch(snapshot_key).deep_dup

    Receipts::Processing.record_final_result(run, receipt:, amount_result: amount_result)

    aggregate_failures do
      expect(snapshot).to include('state' => 'unavailable', 'reason' => 'missing_diagnostics')
      expect(run.reload.final_result_summary.fetch(snapshot_key)).to eq(snapshot)
    end
  end

  it '上限metadataがない旧runを現在設定で補完しない' do
    run = create(:receipt_analysis_run, receipt:)
    result = amount_result
    expect(SystemSettings).not_to receive(:limits_for)

    Receipts::Processing.record_final_result(run, receipt:, amount_result: result)

    aggregate_failures do
      expect(run.reload.metadata).not_to have_key(limits_key)
      expect(run.final_result_summary.fetch(snapshot_key)).to include('state' => 'unavailable', 'reason' => 'limits_missing')
    end
  end

  it '外側summaryの100 byte sanitationでexact数値を短縮しない' do
    create(:system_setting, key: 'limits.snapshot_string_max_bytes', value: SystemSettings.stored_value(100))
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    result = amount_result
    exact = "123456789012345.#{'1' * 112}"
    result[:amount_engine][:selected_candidate][:computed_items].first[:quantity] = exact

    Receipts::Processing.record_final_result(run, receipt:, amount_result: result)

    snapshot = run.reload.final_result_summary.fetch(snapshot_key)
    expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'computed_items')).to be_present
    expect(snapshot.dig('engine', 'amount_engine', 'selected_candidate', 'computed_items', 0, 'quantity')).to eq(exact)
  end

  it '新規retry runは新上限と自己の結果を保存し親削除後も独立して読める' do
    parent = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_final_result(parent, receipt:, amount_result: amount_result)
    Receipts::Processing.succeed(parent)
    create(:system_setting, key: 'limits.snapshot_amount_evidence_max', value: SystemSettings.stored_value(400))
    child = Receipts::Processing.start(receipt:, source: 'admin_retry', parent_run: parent).run
    Receipts::Processing.copy_retry_snapshots(child, parent_run: parent, include_finalize_decision: true)
    expect(child.reload.final_result_summary).to eq({})

    Receipts::Processing.record_final_result(child, receipt:, amount_result: amount_result(total: 999))
    Receipts::Processing.succeed(child)
    snapshot = child.reload.final_result_summary.fetch(snapshot_key).deep_dup
    parent.destroy!

    aggregate_failures do
      expect(child.reload.parent_run_id).to be_nil
      expect(child.final_result_summary.fetch(snapshot_key)).to eq(snapshot)
      expect(snapshot.dig('limits', 'evidence')).to eq(400)
      expect(snapshot.dig('engine', 'resolved', 'total_amount')).to eq(999)
      expect(Receipts::Processing::Contracts::AmountCalculationRunSnapshot.read(snapshot)).to eq(snapshot)
    end
  end

  it 'snapshot DB保存失敗を利用不可へ変換せず明細と金額をrollbackする' do
    run = prepare_run
    total = receipt.total_amount
    allow_any_instance_of(ReceiptAnalysisRun).to receive(:update!).and_wrap_original do |original, attributes|
      if attributes.key?(:final_result_summary)
        raise ActiveRecord::StatementInvalid, 'snapshot write failed'
      end

      original.call(attributes)
    end

    expect { Receipts::Processing.run_finalize(run) }.to raise_error(ActiveRecord::StatementInvalid, 'snapshot write failed')

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(total)
      expect(receipt.receipt_items).to be_empty
      expect(run.reload.final_result_summary).to eq({})
    end
  end
end
