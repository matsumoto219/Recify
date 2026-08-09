require 'rails_helper'

RSpec.describe Receipts::Editing::ReviewState do
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

  it 'blankのcore fieldから新しいmissing reasonを合成しない' do
    receipt = build(
      :receipt,
      status: 'completed',
      store_name: nil,
      store_address: nil,
      store_phone_number: nil,
      purchased_at: nil,
      payment_method: nil,
      review_reasons: []
    )

    result = resolve(receipt)

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it '既存missing reasonは対応する値がblankの間は維持する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      store_name: nil,
      store_address: nil,
      store_phone_number: nil,
      purchased_at: nil,
      payment_method: nil,
      review_reasons: %w[
        store_name_missing
        store_address_missing
        store_phone_number_missing
        purchased_at_missing
        payment_method_missing
      ]
    )

    result = resolve(receipt, permitted: { total_amount: 100 })

    aggregate_failures do
      expect(result.review_reasons).to contain_exactly(
        'store_name_missing',
        'store_address_missing',
        'store_phone_number_missing',
        'purchased_at_missing',
        'payment_method_missing'
      )
      expect(result.status).to eq('review_needed')
    end
  end

  it '既存missing reasonは対応する値を補完した場合に解除する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      store_name: nil,
      store_address: nil,
      store_phone_number: nil,
      purchased_at: nil,
      payment_method: nil,
      review_reasons: %w[
        store_name_missing
        store_address_missing
        store_phone_number_missing
        purchased_at_missing
        payment_method_missing
      ]
    )

    result = resolve(
      receipt,
      permitted: {
        store_name: '修正済み店舗',
        store_address: '修正済み住所',
        store_phone_number: '03-0000-0000',
        purchased_at: Time.zone.local(2026, 7, 1, 12, 0),
        payment_method: 'cash'
      }
    )

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it '値を再送信しただけではuncertain/conflicted reasonを解除しない' do
    purchased_at = Time.zone.local(2026, 7, 1, 12, 0)
    receipt = build(
      :receipt,
      status: 'review_needed',
      store_name: '確認中店舗',
      store_address: '確認中住所',
      store_phone_number: '03-0000-0000',
      purchased_at: purchased_at,
      payment_method: 'cash',
      review_reasons: %w[
        store_name_uncertain
        store_address_uncertain
        store_phone_number_uncertain
        purchased_at_uncertain
        purchased_at_conflicted
        payment_method_uncertain
      ]
    )

    result = resolve(
      receipt,
      permitted: {
        store_name: receipt.store_name,
        store_address: receipt.store_address,
        store_phone_number: receipt.store_phone_number,
        purchased_at: purchased_at,
        payment_method: receipt.payment_method
      }
    )

    aggregate_failures do
      expect(result.review_reasons).to contain_exactly(
        'store_name_uncertain',
        'store_address_uncertain',
        'store_phone_number_uncertain',
        'purchased_at_uncertain',
        'purchased_at_conflicted',
        'payment_method_uncertain'
      )
      expect(result.status).to eq('review_needed')
    end
  end

  it 'core fieldを実際に変更した場合だけuncertain/conflicted reasonを解除する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      store_name: '変更前店舗',
      store_address: '変更前住所',
      store_phone_number: '03-0000-0000',
      purchased_at: Time.zone.local(2026, 7, 1, 12, 0),
      payment_method: 'cash',
      review_reasons: %w[
        store_name_uncertain
        store_address_uncertain
        store_phone_number_uncertain
        purchased_at_uncertain
        purchased_at_conflicted
        payment_method_uncertain
      ]
    )

    result = resolve(
      receipt,
      permitted: {
        store_name: '変更後店舗',
        store_address: '変更後住所',
        store_phone_number: '06-0000-0000',
        purchased_at: Time.zone.local(2026, 7, 2, 12, 0),
        payment_method: 'credit_card'
      }
    )

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it 'warning-only reasonは保持してcompletedを維持する' do
    receipt = build(
      :receipt,
      status: 'completed',
      review_reasons: [ 'ocr_low_confidence' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(receipt)

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'ocr_low_confidence' ])
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

  it 'item入力があってもOCR全体reasonを自動解除しない' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: %w[ocr_unreadable ocr_low_confidence multiple_receipts_suspected],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(receipt, item_inputs_submitted: true)

    aggregate_failures do
      expect(result.review_reasons).to include(
        'ocr_unreadable',
        'ocr_low_confidence',
        'multiple_receipts_suspected'
      )
      expect(result.status).to eq('review_needed')
    end
  end

  it 'category変更だけではreceipt-level item_tax_rate_uncertainを解除しない' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_tax_rate_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    item = receipt.receipt_items.build(category: nil, tax_rate: BigDecimal('0.10'))

    result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, category: 'food', tax_rate: BigDecimal('0.10') }
        }
      },
      item_inputs_submitted: true
    )

    expect(result.review_reasons).to include('item_tax_rate_uncertain')
  end

  it 'item-level reasonは対応fieldを変更したものだけ解除する' do
    item = ReceiptItem.new(
      category: nil,
      tax_rate: BigDecimal('0.10'),
      needs_review: true,
      review_reasons: %w[item_category_uncertain item_tax_rate_uncertain]
    )

    result = described_class.item_review_state(
      item: item,
      submitted_attributes: {
        category: 'food',
        tax_rate: BigDecimal('0.10')
      }
    )

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(result.needs_review).to be(true)
    end
  end
end
