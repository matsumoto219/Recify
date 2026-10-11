require 'rails_helper'

RSpec.describe 'Discounted tax evidence persistence' do
  let(:receipt) { create(:receipt, :processing, :with_image) }
  let(:ai_result) { nil }
  let(:ocr_result) do
    {
      success: true,
      raw_text: "検証店\n検証品A\n3,240\n値引き -1,080\n検証品B\n33\n小計 2,193",
      lines: [ '検証店', '検証品A', '3,240', '値引き -1,080', '検証品B', '33', '小計 2,193' ],
      candidates: {
        store_name: '検証店',
        purchased_at_text: '2025/06/01 12:00',
        country_region: 'JPN',
        subtotal_amount: 2_193,
        tax_amount: 163,
        items: [
          {
            raw_text: '検証品A', price: 7_200, quantity: BigDecimal('0.45'),
            quantity_unit_code: 'kilogram', line_total: 3_240
          },
          { raw_text: '値引き', line_total: -1_080, tax_rate: 8 },
          { raw_text: '検証品B', price: 33, quantity: 1, line_total: 33, tax_rate: 10 }
        ],
        tax_details: [
          { description: '8%対象', net_amount: 2_160, amount: 160, rate: 8 },
          { description: '10%対象', net_amount: 33, amount: 3, rate: 10 }
        ]
      }
    }
  end

  def ready_run
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    Receipts::Processing.record_ai_normalized_result(run, ai_result) if ai_result
    Receipts::Processing.record_finalize_decision(
      run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: ai_result ? 'ai_success' : 'ocr_only',
        error_code: nil,
        error_message: nil,
        receipt_attributes: {},
        ocr_result: nil,
        ai_result: nil,
        metadata: {}
      )
    )
    run.reload
  end

  shared_examples 'discounted gross totals survive finalize' do
    it 'snapshot再読込後も購入値引きと税込税内訳を一度だけ保存する' do
      run = ready_run

      result = Receipts::Processing.run_finalize(run)

      expect(result.next_step).to eq(:done)
      receipt.reload
      snapshot = run.reload.final_result_summary.fetch('amount_calculation_run_snapshot')
      aggregate_failures do
        expect(receipt).to have_attributes(subtotal_amount: 2_030, tax_amount: 163, total_amount: 2_193)
        expect(receipt.receipt_items.pluck(:line_total)).to contain_exactly(3_240, 33)
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to eq([
          [ 'receipt_discount', 1_080, 'discount' ]
        ])
        expect(receipt.receipt_tax_details.pluck(:rate, :net_amount, :amount)).to contain_exactly(
          [ BigDecimal('0.08'), 2_000, 160 ],
          [ BigDecimal('0.1'), 30, 3 ]
        )
        expect(snapshot.dig('engine', 'resolved')).to include(
          'subtotal_amount' => 2_030, 'tax_amount' => 163, 'total_amount' => 2_193
        )
      end
    end
  end

  context 'OCRの明細税率が欠損している場合' do
    include_examples 'discounted gross totals survive finalize'
  end

  context 'AIが欠損していた明細税率だけを補った場合' do
    let(:ai_result) do
      {
        success: true,
        needs_review: false,
        review_reasons: [],
        receipt_attributes: {},
        receipt_items_attributes: [
          { index: 0, category: 'food', tax_rate: 0.08, needs_review: false },
          { index: 2, category: 'daily_goods', tax_rate: 0.1, needs_review: false }
        ]
      }
    end

    include_examples 'discounted gross totals survive finalize'
  end
end
