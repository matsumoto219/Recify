require 'rails_helper'

RSpec.describe ReceiptEditSaveReviewState do
  def resolve(receipt, permitted: {}, amount_reasons: [], child_review_remaining: false, nested_amount_inputs_submitted: false, item_inputs_submitted: false)
    described_class.call(
      receipt: receipt,
      permitted: permitted.stringify_keys,
      amount_result: { review_reasons: amount_reasons },
      consistency_review_reasons: [],
      child_review_remaining: child_review_remaining,
      nested_amount_inputs_submitted: nested_amount_inputs_submitted,
      item_inputs_submitted: item_inputs_submitted
    )
  end

  it 'nested金額入力がない更新では既存Amount review reasonを維持する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'tax_detail_mismatch' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(receipt, permitted: { total_amount: 100 })

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'tax_detail_mismatch' ])
      expect(result.status).to eq('review_needed')
    end
  end

  it 'nested金額入力を再計算した場合は古いAmount reasonを現在結果へ置き換える' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'tax_detail_mismatch' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(receipt, nested_amount_inputs_submitted: true, item_inputs_submitted: true)

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it 'core fieldが欠損していればAI出力に依存せずmissing reasonを補完する' do
    receipt = build(
      :receipt,
      status: 'completed',
      store_name: nil,
      purchased_at: nil,
      payment_method: nil,
      review_reasons: []
    )

    result = resolve(receipt)

    aggregate_failures do
      expect(result.review_reasons).to include(
        'store_name_missing',
        'purchased_at_missing',
        'payment_method_missing'
      )
      expect(result.status).to eq('review_needed')
    end
  end

  it 'core fieldを明示修正した場合はmissing/uncertain reasonを解除する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      store_name: nil,
      purchased_at: nil,
      payment_method: nil,
      review_reasons: %w[
        store_name_missing
        store_name_uncertain
        purchased_at_missing
        purchased_at_uncertain
        payment_method_missing
        payment_method_uncertain
      ]
    )

    result = resolve(
      receipt,
      permitted: {
        store_name: '修正済み店舗',
        purchased_at: Time.zone.local(2026, 7, 1, 12, 0),
        payment_method: 'cash'
      }
    )

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it '理由を持たない既存review_neededは通常編集だけでcompletedへ変えない' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(receipt, permitted: { total_amount: 200 })

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('review_needed')
    end
  end

  it 'child reviewが残る場合はreceiptをcompletedにしない' do
    receipt = build(
      :receipt,
      status: 'completed',
      review_reasons: [],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(receipt, child_review_remaining: true)

    expect(result.status).to eq('review_needed')
  end
end
