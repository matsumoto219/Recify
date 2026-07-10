require 'rails_helper'

RSpec.describe ReceiptEditSaveConsistencyGuard do
  def amount_result(overrides = {})
    {
      computed: {
        adjusted_item_total: 110,
        purchase_total: 110,
        final_payment_total: 110,
        purchase_adjustment_total: 10,
        payment_adjustment_total: 0,
        payment_amount_sum: 110
      },
      resolved: { total: 110 },
      review_reasons: [],
      safe_to_auto_complete: true,
      selected_candidate_status: 'accepted'
    }.deep_merge(overrides)
  end

  let(:items) do
    [ { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100 } ]
  end
  let(:adjustments) do
    [ { kind: 'bag_fee', amount: 10, sign: 'surcharge', source: 'manual' } ]
  end
  let(:payments) do
    [ { method: '現金', amount: 110 } ]
  end

  it '保存予定childrenとAmount結果が一致する場合は通過する' do
    result = described_class.call(
      receipt_items: items,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      amount_result: amount_result
    )

    aggregate_failures do
      expect(result).to be_consistent
      expect(result.fatal_errors).to be_empty
      expect(result.review_reasons).to be_empty
    end
  end

  it '保存予定childrenの購入合計とresolved totalが異なる場合は保存不能にする' do
    result = described_class.call(
      receipt_items: items,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      amount_result: amount_result(resolved: { total: 60 }, computed: { purchase_total: 60, final_payment_total: 60 })
    )

    aggregate_failures do
      expect(result).not_to be_consistent
      expect(result.fatal_errors).to include(:child_purchase_total_mismatch)
    end
  end

  it '実際の支払合計とsnapshot値が異なる場合は保存不能にする' do
    result = described_class.call(
      receipt_items: items,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      amount_result: amount_result(computed: { payment_amount_sum: 220 })
    )

    aggregate_failures do
      expect(result).not_to be_consistent
      expect(result.fatal_errors).to include(:payment_sum_snapshot_mismatch)
    end
  end

  it '支払額だけがfinal payment totalと異なる場合は保存を許可してreview reasonを補完する' do
    result = described_class.call(
      receipt_items: items,
      receipt_adjustments: adjustments,
      receipt_payments: [ { method: '現金', amount: 50 } ],
      amount_result: amount_result(computed: { payment_amount_sum: 50 })
    )

    aggregate_failures do
      expect(result).to be_consistent
      expect(result.review_reasons).to include('payment_amount_mismatch')
    end
  end

  it '安全に自動完了できない候補にはreview reasonを残す' do
    result = described_class.call(
      receipt_items: items,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      amount_result: amount_result(safe_to_auto_complete: false, selected_candidate_status: 'rejected')
    )

    aggregate_failures do
      expect(result).to be_consistent
      expect(result.review_reasons).to include('calculation_profile_uncertain')
    end
  end
end
