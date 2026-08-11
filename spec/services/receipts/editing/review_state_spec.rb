require 'rails_helper'

RSpec.describe Receipts::Editing::ReviewState do
  def resolve(receipt, permitted: {}, amount_reasons: [], amount_needs_review: false, child_review_remaining: false, nested_amount_inputs_submitted: false, item_inputs_submitted: false, adjustment_absence_confirmed: false)
    described_class.call(
      receipt: receipt,
      permitted: permitted.stringify_keys,
      amount_result: { review_reasons: amount_reasons, needs_review: amount_needs_review },
      consistency_review_reasons: [],
      child_review_remaining: child_review_remaining,
      nested_amount_inputs_submitted: nested_amount_inputs_submitted,
      item_inputs_submitted: item_inputs_submitted,
      adjustment_absence_confirmed: adjustment_absence_confirmed
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

  it '未変更のitem・adjustment入力ではreceipt-level adjustment_uncertainを解除しない' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: 100
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'coupon',
      label: nil,
      amount: 10,
      sign: 'discount',
      source: 'manual',
      needs_review: false,
      review_reasons: []
    )

    result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, price: item.price, quantity: item.quantity }
        },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.id,
            kind: adjustment.kind,
            label: '   ',
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: adjustment.tax_rate
          }
        }
      },
      nested_amount_inputs_submitted: true,
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'adjustment_uncertain' ])
      expect(result.status).to eq('review_needed')
    end
  end

  it 'adjustmentの確認対象fieldを変更した場合はreceipt-level adjustment_uncertainを解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'coupon',
      label: '確認前クーポン',
      amount: 10,
      sign: 'discount',
      source: 'manual',
      needs_review: false,
      review_reasons: []
    )
    permitted = Receipts::EditForm.call(
      receipt: receipt,
      attributes: {
        'receipt_adjustments_attributes' => {
          '0' => { 'id' => adjustment.id, 'label' => '確認済みクーポン' }
        }
      }
    )

    result = resolve(
      receipt,
      permitted: permitted,
      nested_amount_inputs_submitted: true
    )
    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it '新規manual adjustmentを確認済み状態で追加した場合はreceipt-level adjustment_uncertainを解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    permitted = Receipts::EditForm.call(
      receipt: receipt,
      attributes: {
        'receipt_adjustments_attributes' => {
          '0' => {
            'kind' => 'coupon',
            'label' => '確認済みクーポン',
            'amount' => '10',
            'sign' => 'discount',
            'tax_rate' => ''
          }
        }
      }
    )

    result = resolve(
      receipt,
      permitted: permitted,
      nested_amount_inputs_submitted: true
    )
    non_empty_marker_result = resolve(
      receipt,
      permitted: {
        receipt_adjustments_attributes: {
          '0' => {
            source: 'manual',
            needs_review: false,
            review_reasons: [ 'unknown_reason' ]
          }
        }
      },
      nested_amount_inputs_submitted: true
    )

    aggregate_failures do
      expect(permitted.dig('receipt_adjustments_attributes', '0')).to include(
        'source' => 'manual',
        'needs_review' => false,
        'review_reasons' => []
      )
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
      expect(non_empty_marker_result.review_reasons).to eq([ 'adjustment_uncertain' ])
    end
  end

  it 'candidate 0のreceipt-level adjustment_uncertainは既存行の削除で解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'coupon',
      label: '削除対象クーポン',
      amount: 10,
      sign: 'discount',
      source: 'manual',
      needs_review: false,
      review_reasons: []
    )

    result = resolve(
      receipt,
      permitted: {
        receipt_adjustments_attributes: {
          '0' => { id: adjustment.id, _destroy: '1' }
        }
      },
      nested_amount_inputs_submitted: true
    )

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it '調整行がないreceipt-level adjustment_uncertainは明示的な「調整なし」確認でだけ解除する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    unconfirmed_result = resolve(receipt)
    confirmed_result = resolve(receipt, adjustment_absence_confirmed: true)

    aggregate_failures do
      expect(unconfirmed_result.review_reasons).to eq([ 'adjustment_uncertain' ])
      expect(unconfirmed_result.status).to eq('review_needed')
      expect(confirmed_result.review_reasons).to be_empty
      expect(confirmed_result.status).to eq('completed')
    end
  end

  it '「調整なし」確認は他の理由を維持し、調整行が存在する場合は解除に使わない' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: %w[adjustment_uncertain ocr_unreadable],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'coupon',
      label: '既存クーポン',
      amount: 10,
      sign: 'discount',
      source: 'manual',
      needs_review: false,
      review_reasons: []
    )

    existing_adjustment_result = resolve(receipt, adjustment_absence_confirmed: true)
    adjustment.destroy!
    receipt.reload
    absent_result = resolve(receipt, adjustment_absence_confirmed: true)

    aggregate_failures do
      expect(existing_adjustment_result.review_reasons).to contain_exactly('adjustment_uncertain', 'ocr_unreadable')
      expect(existing_adjustment_result.status).to eq('review_needed')
      expect(absent_result.review_reasons).to eq([ 'ocr_unreadable' ])
      expect(absent_result.status).to eq('review_needed')
    end
  end

  it '未保存または保存済みと照合できない調整行がある場合は「調整なし」確認でreasonを解除しない' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(
      receipt,
      permitted: {
        receipt_adjustments_attributes: {
          '0' => { kind: 'coupon', label: '入力中クーポン', amount: 10, sign: 'discount' }
        }
      },
      adjustment_absence_confirmed: true
    )
    unknown_id_result = resolve(
      receipt,
      permitted: {
        receipt_adjustments_attributes: {
          '0' => { id: '999999', kind: 'coupon', label: '不明IDクーポン', amount: 10, sign: 'discount' }
        }
      },
      adjustment_absence_confirmed: true
    )

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'adjustment_uncertain' ])
      expect(result.status).to eq('review_needed')
      expect(unknown_id_result.review_reasons).to eq([ 'adjustment_uncertain' ])
      expect(unknown_id_result.status).to eq('review_needed')
    end
  end

  it '複数のreasonless needs_review adjustmentは順次確認して全件解消するまで理由を維持する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    first = receipt.receipt_adjustments.create!(
      kind: 'coupon', label: '確認前クーポンA', amount: 10, sign: 'discount',
      source: 'ai', needs_review: true, review_reasons: []
    )
    second = receipt.receipt_adjustments.create!(
      kind: 'coupon', label: '確認前クーポンB', amount: 5, sign: 'discount',
      source: 'ai', needs_review: true, review_reasons: []
    )
    attributes_for = lambda do |adjustment, label|
      {
        'id' => adjustment.id,
        'kind' => adjustment.kind,
        'label' => label,
        'amount' => adjustment.amount,
        'sign' => adjustment.sign,
        'tax_rate' => adjustment.tax_rate
      }
    end

    first_permitted = Receipts::EditForm.call(
      receipt: receipt,
      attributes: {
        'receipt_adjustments_attributes' => {
          '0' => attributes_for.call(first, '確認済みクーポンA')
        }
      }
    )
    partial_result = resolve(
      receipt,
      permitted: first_permitted,
      nested_amount_inputs_submitted: true
    )

    first.update!(
      label: '確認済みクーポンA',
      source: 'manual',
      needs_review: false,
      review_reasons: []
    )
    receipt.update!(status: partial_result.status, review_reasons: partial_result.review_reasons)

    second_permitted = Receipts::EditForm.call(
      receipt: receipt,
      attributes: {
        'receipt_adjustments_attributes' => {
          '0' => attributes_for.call(second, '確認済みクーポンB')
        }
      }
    )
    complete_result = resolve(
      receipt,
      permitted: second_permitted,
      nested_amount_inputs_submitted: true
    )

    aggregate_failures do
      expect(partial_result.review_reasons).to eq([ 'adjustment_uncertain' ])
      expect(partial_result.status).to eq('review_needed')
      expect(complete_result.review_reasons).to be_empty
      expect(complete_result.status).to eq('completed')
    end
  end

  it '明示reasonとreasonless needs_review adjustmentが混在する場合は両方を候補にする' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'adjustment_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    exact = receipt.receipt_adjustments.create!(
      kind: 'coupon', label: '明示対象', amount: 10, sign: 'discount',
      source: 'ai', needs_review: true, review_reasons: [ 'adjustment_uncertain' ]
    )
    generic = receipt.receipt_adjustments.create!(
      kind: 'coupon', label: '汎用対象', amount: 5, sign: 'discount',
      source: 'ai', needs_review: true, review_reasons: []
    )
    attributes_for = lambda do |adjustment, label|
      {
        'id' => adjustment.id,
        'kind' => adjustment.kind,
        'label' => label,
        'amount' => adjustment.amount,
        'sign' => adjustment.sign,
        'tax_rate' => adjustment.tax_rate
      }
    end
    partial_permitted = Receipts::EditForm.call(
      receipt: receipt,
      attributes: {
        'receipt_adjustments_attributes' => {
          '0' => attributes_for.call(exact, '明示確認済み')
        }
      }
    )
    complete_permitted = Receipts::EditForm.call(
      receipt: receipt,
      attributes: {
        'receipt_adjustments_attributes' => {
          '0' => attributes_for.call(exact, '明示確認済み'),
          '1' => attributes_for.call(generic, '汎用確認済み')
        }
      }
    )

    partial_result = resolve(receipt, permitted: partial_permitted, nested_amount_inputs_submitted: true)
    complete_result = resolve(receipt, permitted: complete_permitted, nested_amount_inputs_submitted: true)

    aggregate_failures do
      expect(partial_result.review_reasons).to eq([ 'adjustment_uncertain' ])
      expect(complete_result.review_reasons).to be_empty
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

  it '表示形式の日本電話番号を再送信してもstore_phone_number_uncertainを解除しない' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      store_phone_number: '+81312345678',
      review_reasons: [ 'store_phone_number_uncertain' ]
    )

    result = resolve(receipt, permitted: { store_phone_number: '03-1234-5678' })

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'store_phone_number_uncertain' ])
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

  it 'Amount側で確認必須へ昇格したwarningはreview_neededを維持する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'price_tax_inclusion_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(
      receipt,
      amount_reasons: [ 'price_tax_inclusion_uncertain' ],
      amount_needs_review: true,
      nested_amount_inputs_submitted: true
    )

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'price_tax_inclusion_uncertain' ])
      expect(result.status).to eq('review_needed')
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
      expect(result.needs_review).to be(false)
    end
  end

  it 'item-level reasonの対応fieldをblankまたは不正値へ変更しても解除しない' do
    item = ReceiptItem.new(
      category: 'food',
      needs_review: true,
      review_reasons: [ 'item_category_uncertain' ]
    )

    blank_result = described_class.item_review_state(
      item: item,
      submitted_attributes: { category: '' }
    )
    invalid_result = described_class.item_review_state(
      item: item,
      submitted_attributes: { category: 'unsupported' }
    )

    aggregate_failures do
      expect(blank_result.review_reasons).to eq([ 'item_category_uncertain' ])
      expect(blank_result.needs_review).to be(true)
      expect(invalid_result.review_reasons).to eq([ 'item_category_uncertain' ])
      expect(invalid_result.needs_review).to be(true)
    end
  end

  it 'blocking item reasonの解除後にwarningだけが残る場合はneeds_reviewを解除する' do
    item = ReceiptItem.new(
      confirmed_name: '確認前商品',
      tax_rate: BigDecimal('0.10'),
      needs_review: true,
      review_reasons: %w[item_name_uncertain item_tax_rate_uncertain]
    )

    result = described_class.item_review_state(
      item: item,
      submitted_attributes: {
        confirmed_name: '確認済み商品',
        tax_rate: BigDecimal('0.10')
      }
    )

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(result.needs_review).to be(false)
    end
  end

  it 'receipt-level item reasonは全てのactive childで解消するまで維持する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    first = receipt.receipt_items.create!(
      confirmed_name: '確認前商品A',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )
    second = receipt.receipt_items.create!(
      confirmed_name: '確認前商品B',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )

    partial_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: first.id, confirmed_name: '確認済み商品A' }
        }
      },
      item_inputs_submitted: true
    )
    complete_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: first.id, confirmed_name: '確認済み商品A' },
          '1' => { id: second.id, confirmed_name: '確認済み商品B' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(partial_result.review_reasons).to eq([ 'item_name_uncertain' ])
      expect(partial_result.status).to eq('review_needed')
      expect(complete_result.review_reasons).to be_empty
      expect(complete_result.status).to eq('completed')
    end
  end

  it 'review対象itemの削除はactive child集合に基づいてreceipt-level reasonを同期する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    first = receipt.receipt_items.create!(
      confirmed_name: '削除対象商品A',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )
    second = receipt.receipt_items.create!(
      confirmed_name: '削除対象商品B',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )
    receipt.receipt_items.create!(
      confirmed_name: '確認済み商品',
      quantity_unit_code: 'each',
      needs_review: false,
      review_reasons: []
    )

    partial_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: first.id, _destroy: '1' }
        }
      },
      item_inputs_submitted: true
    )
    complete_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: first.id, _destroy: '1' },
          '1' => { id: second.id, _destroy: '1' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(partial_result.review_reasons).to eq([ 'item_name_uncertain' ])
      expect(complete_result.review_reasons).to be_empty
    end
  end

  it 'candidate 0のlegacy item reasonは対応fieldの有効な実変更だけで解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '確認前商品',
      quantity_unit_code: 'each',
      needs_review: false,
      review_reasons: []
    )

    blank_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '' }
        }
      },
      item_inputs_submitted: true
    )
    unrelated_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, category: 'food' }
        }
      },
      item_inputs_submitted: true
    )
    resolved_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '確認済み商品' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(blank_result.review_reasons).to eq([ 'item_name_uncertain' ])
      expect(unrelated_result.review_reasons).to eq([ 'item_name_uncertain' ])
      expect(resolved_result.review_reasons).to be_empty
      expect(resolved_result.status).to eq('completed')
    end
  end

  it 'candidate 0のlegacy item reasonは対応fieldを持つ新規item追加でも解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )

    result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => {
            confirmed_name: '確認済み商品',
            quantity_unit_code: 'each'
          }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(result.review_reasons).to be_empty
      expect(result.status).to eq('completed')
    end
  end

  it 'reasonless needs_review itemは継承したreceipt-level reasonを有効な変更で解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '確認前商品',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: []
    )

    blank_state = described_class.item_review_state(
      item: item,
      submitted_attributes: { confirmed_name: '' },
      inherited_review_reasons: receipt.review_reasons
    )
    resolved_state = described_class.item_review_state(
      item: item,
      submitted_attributes: { confirmed_name: '確認済み商品' },
      inherited_review_reasons: receipt.review_reasons
    )
    receipt_state = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '確認済み商品' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(blank_state.needs_review).to be(true)
      expect(blank_state.review_reasons).to be_empty
      expect(resolved_state.needs_review).to be(false)
      expect(resolved_state.review_reasons).to be_empty
      expect(receipt_state.review_reasons).to be_empty
      expect(receipt_state.status).to eq('completed')
    end
  end

  it 'generic itemでblocking解消後に残る継承warningを保存し、次回編集で解除する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: %w[item_name_uncertain item_tax_rate_uncertain],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '確認前商品',
      tax_rate: BigDecimal('0.10'),
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: []
    )

    first_item_state = described_class.item_review_state(
      item: item,
      submitted_attributes: { confirmed_name: '確認済み商品', tax_rate: BigDecimal('0.10') },
      inherited_review_reasons: receipt.review_reasons
    )
    first_receipt_state = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '確認済み商品', tax_rate: BigDecimal('0.10') }
        }
      },
      item_inputs_submitted: true
    )

    item.update!(
      confirmed_name: '確認済み商品',
      needs_review: first_item_state.needs_review,
      review_reasons: first_item_state.review_reasons
    )
    receipt.update!(
      status: first_receipt_state.status,
      review_reasons: first_receipt_state.review_reasons
    )

    second_item_state = described_class.item_review_state(
      item: item,
      submitted_attributes: { tax_rate: BigDecimal('0.08') },
      inherited_review_reasons: receipt.review_reasons
    )
    second_receipt_state = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: item.id, tax_rate: BigDecimal('0.08') }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(first_item_state.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(first_item_state.needs_review).to be(false)
      expect(first_receipt_state.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(first_receipt_state.status).to eq('completed')
      expect(second_item_state.review_reasons).to be_empty
      expect(second_item_state.needs_review).to be(false)
      expect(second_receipt_state.review_reasons).to be_empty
      expect(second_receipt_state.status).to eq('completed')
    end
  end

  it 'receipt-level item reasonは全てのreasonless needs_review itemで解消するまで維持する' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    first = receipt.receipt_items.create!(
      confirmed_name: '確認前商品A',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: []
    )
    second = receipt.receipt_items.create!(
      confirmed_name: '確認前商品B',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: []
    )

    partial_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: first.id, confirmed_name: '確認済み商品A' }
        }
      },
      item_inputs_submitted: true
    )
    complete_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: first.id, confirmed_name: '確認済み商品A' },
          '1' => { id: second.id, confirmed_name: '確認済み商品B' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(partial_result.review_reasons).to eq([ 'item_name_uncertain' ])
      expect(partial_result.status).to eq('review_needed')
      expect(complete_result.review_reasons).to be_empty
      expect(complete_result.status).to eq('completed')
    end
  end

  it 'exact childとreasonless needs_review childが混在する場合は両方を候補にする' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    exact = receipt.receipt_items.create!(
      confirmed_name: '明示対象商品',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )
    generic = receipt.receipt_items.create!(
      confirmed_name: '汎用対象商品',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: []
    )

    partial_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: generic.id, confirmed_name: '汎用確認済み商品' }
        }
      },
      item_inputs_submitted: true
    )
    complete_result = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: exact.id, confirmed_name: '明示確認済み商品' },
          '1' => { id: generic.id, confirmed_name: '汎用確認済み商品' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(partial_result.review_reasons).to eq([ 'item_name_uncertain' ])
      expect(partial_result.status).to eq('review_needed')
      expect(complete_result.review_reasons).to be_empty
      expect(complete_result.status).to eq('completed')
    end
  end

  it '明示reasonが異なるneeds_review itemを別reasonの候補に含めない' do
    receipt = create(
      :receipt,
      status: 'review_needed',
      review_reasons: %w[item_name_uncertain item_category_uncertain],
      purchased_at: Time.current,
      payment_method: 'cash'
    )
    name_item = receipt.receipt_items.create!(
      confirmed_name: '確認前商品',
      category: 'food',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )
    category_item = receipt.receipt_items.create!(
      confirmed_name: 'カテゴリ確認商品',
      category: 'other',
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_category_uncertain' ]
    )

    name_item_state = described_class.item_review_state(
      item: name_item,
      submitted_attributes: { confirmed_name: '確認済み商品', category: 'food' },
      inherited_review_reasons: receipt.review_reasons
    )
    receipt_state = resolve(
      receipt,
      permitted: {
        receipt_items_attributes: {
          '0' => { id: name_item.id, confirmed_name: '確認済み商品', category: 'food' },
          '1' => { id: category_item.id, confirmed_name: category_item.confirmed_name, category: 'other' }
        }
      },
      item_inputs_submitted: true
    )

    aggregate_failures do
      expect(name_item_state.review_reasons).to be_empty
      expect(name_item_state.needs_review).to be(false)
      expect(receipt_state.review_reasons).to eq([ 'item_category_uncertain' ])
      expect(receipt_state.status).to eq('review_needed')
    end
  end

  it 'needs_review itemはchild reasonとreceipt-level item reasonを重複保存せずに評価する' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_name_uncertain' ]
    )
    item = receipt.receipt_items.build(
      confirmed_name: '確認前商品',
      category: nil,
      quantity_unit_code: 'each',
      needs_review: true,
      review_reasons: [ 'item_category_uncertain' ]
    )

    partial_state = described_class.item_review_state(
      item: item,
      submitted_attributes: { confirmed_name: '確認済み商品' },
      inherited_review_reasons: receipt.review_reasons
    )
    complete_state = described_class.item_review_state(
      item: item,
      submitted_attributes: { confirmed_name: '確認済み商品', category: 'food' },
      inherited_review_reasons: receipt.review_reasons
    )

    aggregate_failures do
      expect(partial_state.review_reasons).to eq([ 'item_category_uncertain' ])
      expect(partial_state.needs_review).to be(true)
      expect(complete_state.review_reasons).to be_empty
      expect(complete_state.needs_review).to be(false)
    end
  end

  it 'warning-only itemは同じ値の再送信でneeds_reviewをfalseからtrueへ変えない' do
    item = ReceiptItem.new(
      tax_rate: BigDecimal('0.10'),
      needs_review: false,
      review_reasons: [ 'item_tax_rate_uncertain' ]
    )

    result = described_class.item_review_state(
      item: item,
      submitted_attributes: { tax_rate: BigDecimal('0.10') }
    )

    aggregate_failures do
      expect(result.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(result.needs_review).to be(false)
    end
  end
end
