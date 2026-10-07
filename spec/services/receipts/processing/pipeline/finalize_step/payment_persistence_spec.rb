require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep do
  let(:receipt) { create(:receipt, :processing, :with_image) }
  let(:ocr_result) do
    {
      success: true,
      lines: [
        '架空検証店', '2026/06/18 12:30', '架空品A 540', 'eGift適用 0',
        '架空品B 260', 'eGift適用 0', '小計 800', '消費税 64', '合計 864',
        'eGift適用 600', 'eGift適用 400', '釣銭 0'
      ],
      candidates: {
        country_region: 'JPN',
        store_name: '架空検証店',
        purchased_at_text: '2026/06/18 12:30',
        subtotal_amount: 800,
        tax_amount: 64,
        total_amount: 864,
        payment_method_text: 'eGift',
        items: [
          { raw_text: '架空品A', price: 540, quantity: 1, line_total: 540, tax_rate: BigDecimal('0.08'), confidence: 0.99 },
          { raw_text: '架空品B', price: 260, quantity: 1, line_total: 260, tax_rate: BigDecimal('0.08'), confidence: 0.99 }
        ],
        tax_details: [ { rate: BigDecimal('0.08'), net_amount: 800, amount: 64, description: '外税8%' } ],
        payments: []
      }
    }
  end
  let(:ai_result) do
    {
      success: true,
      needs_review: true,
      review_reasons: [ 'payment_method_missing' ],
      receipt_attributes: { payment_method: 'cash', purchased_at: Time.zone.parse('2026-06-18 12:30:00') },
      receipt_items_attributes: [
        { index: 0, category: 'food', tax_rate: BigDecimal('0.08'), needs_review: false, confidence: 0.99 },
        { index: 1, category: 'food', tax_rate: BigDecimal('0.08'), needs_review: false, confidence: 0.99 }
      ]
    }
  end

  def decision(strategy: 'ai_success', **values)
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: strategy,
      ocr_result:,
      ai_result:,
      **values
    )
  end

  it '商品の0円適用と額面を保存せず購入額・税を維持して実充当額だけ保存する' do
    step = described_class.new(receipt:, decision: decision)
    step.call

    aggregate_failures do
      expect(receipt.reload).to have_attributes(subtotal_amount: 800, tax_amount: 64, total_amount: 864, payment_method: 'other', status: 'completed')
      expect(receipt.receipt_payments.reload.map { |payment| [ payment.method, payment.amount ] }).to eq([ [ 'eGift', 864 ] ])
      expect(receipt.review_reasons).not_to include('payment_method_missing', 'payment_amount_uncertain')
      expect(step.final_amount_result.dig(:computed, :payment_amount_sum)).to be_nil
      expect(step.final_amount_result.dig(:payment_reconciliation, :payment_amount_sum)).to eq(864)
      expect(receipt.amount_calculation_profile.dig('amount_engine', 'selected_candidate', 'evidence')).not_to include(include('source' => 'receipt_payments'))
    end
  end

  it '精算欄に未分類金額があれば方法だけ保持し金額と税の確認理由を分離する' do
    ocr_result[:lines] << '未分類精算 120'
    ai_result[:review_reasons] << 'tax_amount_mismatch'
    step = described_class.new(receipt:, decision: decision)
    step.call

    aggregate_failures do
      expect(receipt.reload.payment_method).to eq('other')
      expect(receipt.receipt_payments.reload.pluck(:amount)).to eq([ nil, nil ])
      expect(receipt.review_reasons).to include('payment_amount_uncertain', 'tax_amount_mismatch')
      expect(receipt.review_reasons).not_to include('payment_method_missing')
      expect(step.final_amount_result.dig(:payment_reconciliation, :payment_amount_sum)).to be_nil
    end
  end

  it 'snapshotからのFinalizeと同じrunのreplayで充当額の意味を維持し二重行を作らない' do
    run = create(
      :receipt_analysis_run,
      receipt:,
      metadata: {
        'amount_calculation_snapshot_limits_v1' => Receipts::Processing::Contracts::AmountCalculationSnapshotLimits.capture
      }
    )
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    Receipts::Processing.record_ai_normalized_result(run, ai_result)
    Receipts::Processing.record_finalize_decision(run, decision)

    ReceiptFinalizeJob.perform_now(run_id: run.id)
    first_payment = receipt.receipt_payments.reload.sole.attributes
    first_summary = run.reload.final_result_summary.deep_dup
    ReceiptFinalizeJob.perform_now(run_id: run.id)

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(864)
      expect(receipt.receipt_payments.reload.sole.attributes).to eq(first_payment)
      expect(first_payment).to include('method' => 'eGift', 'amount' => 864)
      expect(run.reload.final_result_summary).to eq(first_summary)
      snapshot = first_summary.fetch('amount_calculation_run_snapshot')
      expect(snapshot.fetch('state')).to eq('partial')
      expect(Receipts::Processing.amount_calculation_run_snapshot(snapshot)).to eq(snapshot)
      expect(first_summary.dig('amount_calculation_run_snapshot', 'saved_profile', 'payment_reconciliation', 'payment_amount_sum')).to eq(864)
      expect(run.ocr_result_snapshot.dig('candidates', 'payments')).to eq([])
    end
  end

  it 'OCR-onlyでも実充当額を保存し既存のreview_needed契約を維持する' do
    described_class.new(receipt:, decision: decision(strategy: 'ocr_only')).call

    expect(receipt.reload.status).to eq('review_needed')
    expect(receipt.receipt_payments.reload.pluck(:amount)).to eq([ 864 ])
  end

  it '欠損measurementのOCR購入額を保持する経路でも実際の保存額で支払照合する' do
    ocr_result.replace(
      success: true,
      lines: [ '架空検証店', '2026/06/18 12:30', '計量品 140円 8.12L', '合計 800円', '現金支払 800円' ],
      candidates: {
        country_region: 'JPN',
        store_name: '架空検証店',
        purchased_at_text: '2026/06/18 12:30',
        total_amount: 800,
        subtotal_amount: 800,
        tax_amount: 0,
        payment_method_text: '現金',
        items: [
          {
            raw_text: '計量品',
            price: 140,
            quantity: '8.12',
            quantity_unit_code: 'liter',
            quantity_unit_status: 'known',
            line_total: nil,
            tax_rate: 0,
            confidence: 0.99
          }
        ],
        payments: [],
        tax_details: []
      }
    )
    ai_result[:receipt_attributes][:payment_method] = 'cash'
    ai_result[:receipt_items_attributes] = [ { index: 0, category: 'other', needs_review: false } ]
    calculated_result = nil
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **arguments|
      # AmountとOCR保持額が異なる境界を再現し、Finalize自身の保存判断・transactionは実行する。
      calculated_result = original.call(**arguments).deep_dup
      calculated_result[:computed][:purchase_total] = 1_000
      calculated_result[:computed][:final_payment_total] = 1_000
      calculated_result[:resolved].merge!(total: 600, subtotal: 600, tax: 0)
      calculated_result
    end

    step = described_class.new(receipt:, decision: decision)
    step.call

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(800)
      expect(receipt.receipt_items.reload.sole.line_total).to be_nil
      expect(receipt.receipt_payments.reload.pluck(:amount)).to eq([ 800 ])
      expect(step.final_amount_result[:payment_reconciliation]).to include(
        purchase_total: 800,
        final_payment_total: 800,
        payment_delta: 0,
        matched: true
      )
      expect(step.final_amount_result[:review_reasons]).not_to include('payment_amount_mismatch')
      expect(step.final_amount_result[:computed]).to eq(calculated_result[:computed])
      expect(step.final_amount_result[:amount_engine]).to eq(calculated_result[:amount_engine])
    end
  end

  it 'OCR snapshotの古い方法理由だけを解除し別の税確認理由を保持する' do
    ocr_result[:candidates][:review_reasons] = [ 'payment_method_missing', 'tax_amount_mismatch' ]
    described_class.new(receipt:, decision: decision).call

    expect(receipt.reload.review_reasons).to include('tax_amount_mismatch')
    expect(receipt.review_reasons).not_to include('payment_method_missing', 'payment_method_uncertain')
    expect(receipt.payment_method).to eq('other')
  end
end
