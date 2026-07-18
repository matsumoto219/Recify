require 'rails_helper'

RSpec.describe 'Receipt edit-save amount contract', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def create_completed_receipt(attributes = {})
    create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: '編集保存テスト店',
      purchased_at: Time.zone.local(2026, 7, 1, 12, 0),
      payment_method: 'cash',
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100,
      **attributes
    )
  end

  def create_item(receipt, attributes = {})
    receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      tax_rate: BigDecimal('0.1'),
      line_total: 100,
      needs_review: false,
      review_reasons: [],
      **attributes
    )
  end

  def item_attributes(item, overrides = {})
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      category: item.category,
      price: item.price,
      quantity: item.quantity.to_s,
      quantity_unit_code: item.quantity_unit_code,
      product_code: item.product_code,
      tax_rate: item.tax_rate.to_d * 100,
      discount_rate: item.discount_rate&.*(100),
      line_total: item.line_total,
      position_index: item.position_index,
      _destroy: '0'
    }.merge(overrides)
  end

  def adjustment_attributes(adjustment, overrides = {})
    {
      id: adjustment.id,
      kind: adjustment.kind,
      label: adjustment.label,
      amount: adjustment.amount,
      sign: adjustment.sign,
      tax_rate: adjustment.tax_rate&.*(100),
      position_index: adjustment.position_index,
      _destroy: '0'
    }.merge(overrides)
  end

  def payment_attributes(payment, overrides = {})
    {
      id: payment.id,
      method: payment.method,
      amount: payment.amount,
      _destroy: '0'
    }.merge(overrides)
  end

  def patch_receipt(receipt, attributes = nil, include_lock_version: true, **keyword_attributes)
    attributes = attributes ? attributes.merge(keyword_attributes) : keyword_attributes
    submitted_attributes = include_lock_version ? { lock_version: receipt.lock_version }.merge(attributes) : attributes

    patch receipt_path(receipt), params: { receipt: submitted_attributes }
  end

  describe 'post-update calculation input' do
    it 'g112相当の袋数量を1から2へ変更すると明細・合計を再計算して支払不一致を残す' do
      receipt = create_completed_receipt(subtotal_amount: 742, tax_amount: 59, total_amount: 801, payment_method: 'e_money')
      food = create_item(
        receipt,
        confirmed_name: '軽減税率商品',
        price: 798,
        tax_rate: BigDecimal('0.08'),
        line_total: 798,
        position_index: 0
      )
      bag = create_item(
        receipt,
        confirmed_name: 'レジ袋中1枚',
        price: 3,
        tax_rate: BigDecimal('0.1'),
        line_total: 3,
        position_index: 1
      )
      receipt.receipt_tax_details.create!(description: '8%対象', rate: BigDecimal('0.08'), net_amount: 739, amount: 59)
      receipt.receipt_tax_details.create!(description: '10%対象', rate: BigDecimal('0.1'), net_amount: 3, amount: 0)
      receipt.receipt_payments.create!(method: 'Suica', amount: 801)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(food),
          '1' => item_attributes(bag, quantity: '2', line_total: '3')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(bag.reload.line_total).to eq(6)
        expect(receipt.subtotal_amount).to eq(745)
        expect(receipt.tax_amount).to eq(59)
        expect(receipt.total_amount).to eq(804)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
      end
    end

    it '保存済み税詳細があってもquantity変更後の明細合計を採用する' do
      receipt = create_completed_receipt
      item = create_item(receipt)
      receipt.receipt_tax_details.create!(description: '10%対象', rate: BigDecimal('0.1'), net_amount: 91, amount: 9)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: '2', line_total: '100')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(item.reload.line_total).to eq(200)
        expect(receipt.subtotal_amount).to eq(182)
        expect(receipt.tax_amount).to eq(18)
        expect(receipt.total_amount).to eq(200)
      end
    end

    it '保存済み税詳細があってもprice変更後の明細合計を採用する' do
      receipt = create_completed_receipt
      item = create_item(receipt)
      receipt.receipt_tax_details.create!(description: '10%対象', rate: BigDecimal('0.1'), net_amount: 91, amount: 9)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, price: '200', line_total: '100')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(item.reload.line_total).to eq(200)
        expect(receipt.subtotal_amount).to eq(182)
        expect(receipt.tax_amount).to eq(18)
        expect(receipt.total_amount).to eq(200)
      end
    end

    it '保存済み税詳細があってもtax_rate変更後の税額と税率を再計算する' do
      receipt = create_completed_receipt
      item = create_item(receipt)
      receipt.receipt_tax_details.create!(description: '10%対象', rate: BigDecimal('0.1'), net_amount: 91, amount: 9)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, tax_rate: '8')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(item.reload.tax_rate).to eq(BigDecimal('0.08'))
        expect(receipt.subtotal_amount).to eq(93)
        expect(receipt.tax_amount).to eq(7)
        expect(receipt.tax_rate).to eq(BigDecimal('0.08'))
        expect(receipt.receipt_tax_details.pluck(:rate)).to contain_exactly(BigDecimal('0.08'))
      end
    end

    it '一部itemだけPATCHしても未送信の既存itemを含めて再計算する' do
      receipt = create_completed_receipt(subtotal_amount: 100, tax_amount: 0, total_amount: 100)
      edited = create_item(receipt, confirmed_name: '編集商品', price: 50, tax_rate: nil, line_total: 50, position_index: 0)
      create_item(receipt, confirmed_name: '未送信商品', price: 50, tax_rate: nil, line_total: 50, position_index: 1)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(edited, price: '60', line_total: '50', tax_rate: '')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(edited.reload.line_total).to eq(60)
        expect(receipt.receipt_items.sum(:line_total)).to eq(110)
        expect(receipt.total_amount).to eq(110)
      end
    end

    it '一部adjustmentだけPATCHしても未送信の既存adjustmentを含めて再計算する' do
      receipt = create_completed_receipt(subtotal_amount: 125, tax_amount: 0, total_amount: 125)
      create_item(receipt, price: 100, tax_rate: nil, line_total: 100)
      edited = receipt.receipt_adjustments.create!(
        kind: 'delivery_fee', label: '編集送料', amount: 10, sign: 'surcharge', source: 'manual', needs_review: false
      )
      receipt.receipt_adjustments.create!(
        kind: 'bag_fee', label: '未送信袋代', amount: 15, sign: 'surcharge', source: 'manual', needs_review: false
      )

      patch_receipt(
        receipt,
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(edited, amount: '20')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(edited.reload.amount).to eq(20)
        expect(receipt.total_amount).to eq(135)
      end
    end

    it 'サービス料をクーポンへ変更して購入合計と支払不一致を再計算する' do
      receipt = create_completed_receipt(subtotal_amount: 200, tax_amount: 20, total_amount: 220)
      item = create_item(receipt, price: 100, quantity: 2, line_total: 200)
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'service_charge',
        label: 'サービス料',
        amount: 20,
        sign: 'surcharge',
        source: 'manual',
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        description: '10%対象', rate: BigDecimal('0.1'), net_amount: 200, amount: 20
      )
      receipt.receipt_payments.create!(method: '現金', amount: 200)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item)
        },
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(adjustment, kind: 'coupon', sign: 'discount')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(adjustment.reload.kind).to eq('coupon')
        expect(adjustment.sign).to eq('discount')
        expect(receipt.total_amount).to eq(180)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
        expect(receipt.receipt_tax_details.pluck(:net_amount, :amount)).to contain_exactly([ 164, 16 ])
      end
    end

    it 'クーポンをサービス料へ変更して購入合計と税詳細を再計算する' do
      receipt = create_completed_receipt(subtotal_amount: 164, tax_amount: 16, total_amount: 180)
      item = create_item(receipt, price: 100, quantity: 2, line_total: 200)
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'coupon',
        label: 'クーポン',
        amount: 20,
        sign: 'discount',
        source: 'manual',
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        description: '10%対象', rate: BigDecimal('0.1'), net_amount: 164, amount: 16
      )
      receipt.receipt_payments.create!(method: '現金', amount: 180)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item)
        },
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(
            adjustment,
            kind: 'service_charge',
            label: 'サービス料',
            sign: 'surcharge'
          )
        }
      )
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(adjustment.reload.kind).to eq('service_charge')
        expect(adjustment.sign).to eq('surcharge')
        expect(receipt.total_amount).to eq(220)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
        expect(receipt.receipt_tax_details.pluck(:net_amount, :amount)).to contain_exactly([ 200, 20 ])
      end
    end

    it '支払調整をクーポンへ変更して購入合計へ反映する' do
      [
        { kind: 'point_usage', label: 'ポイント利用' },
        { kind: 'other', label: 'キャッシュレス還元' },
        { kind: 'other', label: 'payment discount' }
      ].each do |initial|
        receipt = create_completed_receipt(subtotal_amount: 100, tax_amount: 0, total_amount: 100)
        create_item(receipt, tax_rate: BigDecimal('0'), line_total: 100)
        adjustment = receipt.receipt_adjustments.create!(
          kind: initial[:kind],
          label: initial[:label],
          amount: 20,
          sign: 'discount',
          source: 'manual',
          needs_review: false
        )
        receipt.receipt_payments.create!(method: '現金', amount: 80)

        patch_receipt(
          receipt,
          receipt_adjustments_attributes: {
            '0' => adjustment_attributes(
              adjustment,
              kind: 'coupon',
              label: 'クーポン',
              sign: 'discount',
              tax_rate: '0'
            )
          }
        )
        receipt.reload

        aggregate_failures initial[:label] do
          expect(response).to redirect_to(receipt_path(receipt))
          expect(adjustment.reload.kind).to eq('coupon')
          expect(receipt.total_amount).to eq(80)
          expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(80)
        end
      end
    end

    it 'labelだけでeffectが変わる場合も古い税詳細を使わず再計算する' do
      receipt = create_completed_receipt(
        subtotal_amount: 82,
        tax_amount: 8,
        total_amount: 90,
        payment_method: 'e_money'
      )
      create_item(receipt)
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'receipt_discount',
        label: 'レシート値引き',
        amount: 10,
        sign: 'discount',
        tax_rate: BigDecimal('0.10'),
        source: 'manual',
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        description: '10%対象', rate: BigDecimal('0.10'), net_amount: 82, amount: 8
      )
      receipt.receipt_payments.create!(method: '電子マネー', amount: 90)

      patch_receipt(
        receipt,
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(adjustment, label: 'キャッシュレス還元')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(100)
        expect(receipt.subtotal_amount).to eq(91)
        expect(receipt.tax_amount).to eq(9)
        expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(90)
        expect(receipt.receipt_tax_details.pluck(:net_amount, :amount)).to contain_exactly([ 91, 9 ])
      end
    end

    it 'paymentだけ変更しても支払不一致をstatusへ反映する' do
      receipt = create_completed_receipt
      create_item(receipt)
      payment = receipt.receipt_payments.create!(method: '現金', amount: 100)

      patch_receipt(
        receipt,
        receipt_payments_attributes: {
          '0' => payment_attributes(payment, amount: '50')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(payment.reload.amount).to eq(50)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
      end
    end

    it 'itemが未送信の部分PATCHでは保存済み税詳細を削除しない' do
      receipt = create_completed_receipt
      create_item(receipt)
      tax_detail = receipt.receipt_tax_details.create!(
        description: '10%対象', rate: BigDecimal('0.1'), net_amount: 91, amount: 9
      )

      patch_receipt(receipt, memo: '金額以外を更新')

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.receipt_tax_details).to contain_exactly(tax_detail)
      end
    end

    it '購入日時が未送信の部分PATCHでは保存済み購入日時を消さない' do
      receipt = create_completed_receipt
      purchased_at = receipt.purchased_at

      patch_receipt(receipt, memo: '購入日時以外を更新')

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.purchased_at).to eq(purchased_at)
      end
    end
  end

  describe 'nested child conflict handling' do
    it '同一item IDの二重送信を拒否する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, price: '100', line_total: '100'),
          '1' => item_attributes(item, price: '200', line_total: '200')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.price).to eq(100)
        expect(receipt.reload.total_amount).to eq(100)
      end
    end

    it '同一adjustment IDの二重送信を拒否する' do
      receipt = create_completed_receipt(total_amount: 110, subtotal_amount: 110, tax_amount: 0)
      create_item(receipt, tax_rate: nil)
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'delivery_fee', label: '送料', amount: 10, sign: 'surcharge', source: 'manual', needs_review: false
      )

      patch_receipt(
        receipt,
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(adjustment, amount: '10'),
          '1' => adjustment_attributes(adjustment, amount: '20')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(adjustment.reload.amount).to eq(10)
        expect(receipt.reload.total_amount).to eq(110)
      end
    end

    it '同一payment IDの二重送信を拒否する' do
      receipt = create_completed_receipt
      create_item(receipt)
      payment = receipt.receipt_payments.create!(method: '現金', amount: 100)

      patch_receipt(
        receipt,
        receipt_payments_attributes: {
          '0' => payment_attributes(payment, amount: '100'),
          '1' => payment_attributes(payment, amount: '50')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(payment.reload.amount).to eq(100)
      end
    end

    it '同一item IDの更新と削除が混在する送信を拒否する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, price: '200', line_total: '200'),
          '1' => item_attributes(item, _destroy: '1')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.price).to eq(100)
        expect(receipt.reload.receipt_items).to contain_exactly(item)
        expect(receipt.total_amount).to eq(100)
      end
    end
  end

  describe 'server-side review and item amount integrity' do
    it 'top-level欠損値が未修正ならmissing review reasonsを維持する' do
      receipt = create_completed_receipt(
        purchased_at: nil,
        payment_method: nil,
        status: 'review_needed',
        review_reasons: %w[purchased_at_missing payment_method_missing]
      )
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, category: 'food')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(receipt.purchased_at).to be_nil
        expect(receipt.payment_method).to be_nil
        expect(receipt.review_reasons).to include('purchased_at_missing', 'payment_method_missing')
        expect(receipt.status).to eq('review_needed')
      end
    end

    it '未変更adjustmentのreview stateをフォーム送信だけで解除しない' do
      receipt = create_completed_receipt(status: 'review_needed', review_reasons: [ 'adjustment_uncertain' ])
      create_item(receipt)
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'receipt_discount',
        label: '確認が必要な値引き',
        amount: 10,
        sign: 'discount',
        source: 'ai',
        needs_review: true,
        review_reasons: [ 'adjustment_uncertain' ]
      )

      patch_receipt(
        receipt,
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(adjustment)
        }
      )
      adjustment.reload

      aggregate_failures do
        expect(adjustment.source).to eq('ai')
        expect(adjustment.needs_review).to be(true)
        expect(adjustment.review_reasons).to include('adjustment_uncertain')
        expect(receipt.reload.status).to eq('review_needed')
      end
    end

    it 'category変更だけではitem_tax_rate_uncertainを解除しない' do
      receipt = create_completed_receipt(
        status: 'review_needed',
        review_reasons: [ 'item_tax_rate_uncertain' ]
      )
      item = create_item(
        receipt,
        category: nil,
        needs_review: true,
        review_reasons: [ 'item_tax_rate_uncertain' ]
      )

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, category: 'food')
        }
      )
      receipt.reload
      item.reload

      aggregate_failures do
        expect(item.category).to eq('food')
        expect(item.needs_review).to be(true)
        expect(item.review_reasons).to include('item_tax_rate_uncertain')
        expect(receipt.review_reasons).to include('item_tax_rate_uncertain')
        expect(receipt.status).to eq('review_needed')
      end
    end

    it 'tax_rateを修正した場合はitem_tax_rate_uncertainだけを解除する' do
      receipt = create_completed_receipt(
        status: 'review_needed',
        review_reasons: [ 'item_tax_rate_uncertain' ]
      )
      item = create_item(
        receipt,
        tax_rate: nil,
        needs_review: true,
        review_reasons: [ 'item_tax_rate_uncertain' ]
      )

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, tax_rate: '10')
        }
      )
      receipt.reload
      item.reload

      aggregate_failures do
        expect(item.tax_rate).to eq(BigDecimal('0.10'))
        expect(item.needs_review).to be(false)
        expect(item.review_reasons).to be_empty
        expect(receipt.review_reasons).not_to include('item_tax_rate_uncertain')
        expect(receipt.status).to eq('completed')
      end
    end

    it 'category変更だけでは既存Amount reasonを解除しない' do
      receipt = create_completed_receipt(
        status: 'review_needed',
        review_reasons: [ 'tax_detail_mismatch' ],
        tax_rate: BigDecimal('0.10')
      )
      item = create_item(receipt, category: nil)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, category: 'food')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(item.reload.category).to eq('food')
        expect(receipt.review_reasons).to include('tax_detail_mismatch')
        expect(receipt.status).to eq('review_needed')
      end
    end

    it 'item編集だけではOCR全体reasonを解除しない' do
      receipt = create_completed_receipt(
        status: 'review_needed',
        review_reasons: %w[ocr_unreadable ocr_low_confidence]
      )
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, confirmed_name: '修正済み商品')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(receipt.review_reasons).to include('ocr_unreadable', 'ocr_low_confidence')
        expect(receipt.status).to eq('review_needed')
      end
    end

    it '不正文字列quantityを1へ丸めて保存しない' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: 'abc', line_total: '100')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.quantity).to eq(BigDecimal('1'))
        expect(receipt.reload.total_amount).to eq(100)
      end
    end

    it 'negative quantityを1へ丸めて保存しない' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: '-1', line_total: '100')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.quantity).to eq(BigDecimal('1'))
        expect(receipt.reload.total_amount).to eq(100)
      end
    end

    it 'countable itemは古いhidden line_totalよりpriceとquantityを優先する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: '2', line_total: '100')
        }
      )
      receipt.reload

      aggregate_failures do
        expect(item.reload.line_total).to eq(200)
        expect(receipt.subtotal_amount).to eq(182)
        expect(receipt.tax_amount).to eq(18)
        expect(receipt.total_amount).to eq(200)
      end
    end

    it 'countable itemでpriceが送信されなくても保存済みpriceとquantityから再計算する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            confirmed_name: item.confirmed_name,
            quantity: '1',
            quantity_unit_code: 'each',
            tax_rate: '10',
            line_total: '150',
            _destroy: '0'
          }
        }
      )
      receipt.reload

      aggregate_failures do
        expect(item.reload.price).to eq(100)
        expect(item.line_total).to eq(100)
        expect(receipt.total_amount).to eq(100)
      end
    end

    it '無変更のcountable itemは単価へ割り切れない保存済みgross line_totalを維持する' do
      receipt = create_completed_receipt(subtotal_amount: 390, tax_amount: 31, total_amount: 421)
      item = create_item(
        receipt,
        price: 130,
        quantity: 3,
        original_line_total: 390,
        line_total: 421,
        tax_rate: BigDecimal('0.08')
      )

      patch_receipt(
        receipt,
        memo: '金額以外の更新',
        receipt_items_attributes: {
          '0' => item_attributes(item)
        }
      )
      receipt.reload
      item.reload

      patch_receipt(
        receipt,
        memo: '金額以外の再更新',
        receipt_items_attributes: {
          '0' => item_attributes(item, line_total: '390')
        }
      )
      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.price).to eq(130)
        expect(item.quantity).to eq(BigDecimal('3'))
        expect(item.original_line_total).to eq(390)
        expect(item.line_total).to eq(421)
        expect(receipt.subtotal_amount).to eq(390)
        expect(receipt.tax_amount).to eq(31)
        expect(receipt.total_amount).to eq(421)
      end
    end

    it '非金額編集では保存済みgrossへ投影された割引countable itemを再計算しない' do
      receipt = create_completed_receipt(subtotal_amount: 100, tax_amount: 10, total_amount: 110)
      item = create_item(
        receipt,
        price: 100,
        quantity: 1,
        original_line_total: 100,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 10,
        line_total: 110
      )

      2.times do |index|
        patch_receipt(
          receipt,
          memo: "金額以外の更新#{index}",
          receipt_items_attributes: {
            '0' => item_attributes(item.reload)
          }
        )
        receipt.reload
      end
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.price).to eq(100)
        expect(item.original_line_total).to eq(100)
        expect(item.discount_rate).to eq(BigDecimal('0.1'))
        expect(item.discount_amount).to eq(10)
        expect(item.line_total).to eq(110)
        expect(receipt.subtotal_amount).to eq(100)
        expect(receipt.tax_amount).to eq(10)
        expect(receipt.total_amount).to eq(110)
      end
    end

    it '割引済みcountable itemのquantity変更は現在の単価と数量から割引額を再計算する' do
      receipt = create_completed_receipt(subtotal_amount: 273, tax_amount: 27, total_amount: 300)
      item = create_item(
        receipt,
        price: 300,
        quantity: 2,
        original_line_total: 600,
        discount_rate: BigDecimal('0.5'),
        discount_amount: 300,
        line_total: 300
      )

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: '3', discount_rate: '50', line_total: '300')
        }
      )
      receipt.reload
      item.reload

      aggregate_failures do
        expect(item.original_line_total).to eq(900)
        expect(item.discount_amount).to eq(450)
        expect(item.line_total).to eq(450)
        expect(receipt.total_amount).to eq(450)
      end
    end

    it 'discount_rateを空にしたcountable itemは旧割引を残さない' do
      receipt = create_completed_receipt(subtotal_amount: 273, tax_amount: 27, total_amount: 300)
      item = create_item(
        receipt,
        price: 300,
        quantity: 2,
        original_line_total: 600,
        discount_rate: BigDecimal('0.5'),
        discount_amount: 300,
        line_total: 300
      )

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, discount_rate: '', line_total: '300')
        }
      )
      receipt.reload
      item.reload

      aggregate_failures do
        expect(item.original_line_total).to eq(600)
        expect(item.discount_rate).to be_nil
        expect(item.discount_amount).to be_nil
        expect(item.line_total).to eq(600)
        expect(receipt.total_amount).to eq(600)
      end
    end
  end

  describe 'optimistic locking' do
    it '編集フォームに現在のlock_versionを含める' do
      receipt = create_completed_receipt

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      lock_input = document.at_css('input[name="receipt[lock_version]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(lock_input).to be_present
        expect(lock_input['value']).to eq(receipt.lock_version.to_s)
      end
    end

    it '古いlock_versionの保存を拒否して新しいDB値を維持する' do
      receipt = create_completed_receipt
      stale_lock_version = receipt.lock_version
      receipt.update!(memo: '別タブで保存済み')

      patch_receipt(
        receipt,
        lock_version: stale_lock_version,
        memo: '古いタブの値'
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.form.errors.stale_edit'))
        expect(receipt.reload.memo).to eq('別タブで保存済み')
      end
    end

    it 'lock_versionを省略した保存を拒否してDB値を維持する' do
      receipt = create_completed_receipt

      patch_receipt(
        receipt,
        { memo: 'versionなしの更新' },
        include_lock_version: false
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.form.errors.stale_edit'))
        expect(receipt.reload.memo).not_to eq('versionなしの更新')
      end
    end

    it '現在のlock_versionなら保存してversionを進める' do
      receipt = create_completed_receipt
      current_lock_version = receipt.lock_version

      patch_receipt(
        receipt,
        lock_version: current_lock_version,
        memo: '現在タブの値'
      )

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.memo).to eq('現在タブの値')
        expect(receipt.lock_version).to eq(current_lock_version + 1)
      end
    end

    it 'nested item更新でも親Receiptのlock_versionを進める' do
      receipt = create_completed_receipt
      item = create_item(receipt)
      current_lock_version = receipt.lock_version

      patch_receipt(
        receipt,
        lock_version: current_lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: '2', line_total: '100')
        }
      )

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.lock_version).to eq(current_lock_version + 1)
        expect(item.reload.line_total).to eq(200)
      end
    end
  end

  describe 'strict numeric input' do
    it 'quantityの混在文字列を別の数量へ変換せず拒否する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: 'abc12')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.quantity).to eq(BigDecimal('1'))
        expect(receipt.reload.total_amount).to eq(100)
      end
    end

    it 'adjustment amountの混在文字列を別の金額へ変換せず拒否する' do
      receipt = create_completed_receipt(total_amount: 110, subtotal_amount: 110, tax_amount: 0)
      create_item(receipt, tax_rate: nil)
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'delivery_fee', label: '送料', amount: 10, sign: 'surcharge', source: 'manual', needs_review: false
      )

      patch_receipt(
        receipt,
        receipt_adjustments_attributes: {
          '0' => adjustment_attributes(adjustment, amount: '12abc')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(adjustment.reload.amount).to eq(10)
        expect(receipt.reload.total_amount).to eq(110)
      end
    end

    it 'payment amountの科学表記を別の金額へ変換せず拒否する' do
      receipt = create_completed_receipt
      create_item(receipt)
      payment = receipt.receipt_payments.create!(method: '現金', amount: 100)

      patch_receipt(
        receipt,
        receipt_payments_attributes: {
          '0' => payment_attributes(payment, amount: '1e2')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(payment.reload.amount).to eq(100)
        expect(receipt.reload.total_amount).to eq(100)
      end
    end

    it 'scientific notationのpriceを別の整数へ変換せず拒否する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        memo: '入力保持メモ',
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(
            item,
            confirmed_name: '入力保持商品',
            quantity: '2',
            price: '1e2',
            line_total: '100'
          )
        }
      )

      document = Nokogiri::HTML(response.body)
      item_row = document.at_css('[data-receipt-form-target="itemRow"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css('textarea[name="receipt[memo]"]').text.strip).to eq('入力保持メモ')
        expect(item_row.at_css('input[name$="[confirmed_name]"]')['value']).to eq('入力保持商品')
        expect(item_row.at_css('input[name$="[quantity]"]')['value']).to eq('2')
        expect(item_row.at_css('input[name$="[price]"]')['value']).to eq('1e2')
        expect(item.reload.price).to eq(100)
        expect(item.line_total).to eq(100)
        expect(receipt.reload.total_amount).to eq(100)
      end
    end

    it 'invalid tax_rateを非課税へ変換せず拒否する' do
      receipt = create_completed_receipt
      item = create_item(receipt)

      patch_receipt(
        receipt,
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, tax_rate: 'abc')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.tax_rate).to eq(BigDecimal('0.1'))
        expect(receipt.reload.tax_amount).to eq(9)
      end
    end

    it 'invalid discount_rateを黙って削除せず拒否する' do
      receipt = create_completed_receipt(total_amount: 90, subtotal_amount: 82, tax_amount: 8)
      item = create_item(
        receipt,
        original_line_total: 100,
        discount_amount: 10,
        discount_rate: BigDecimal('0.1'),
        line_total: 90
      )

      patch_receipt(
        receipt,
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, discount_rate: 'abc', line_total: '90')
        }
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.discount_rate).to eq(BigDecimal('0.1'))
        expect(item.line_total).to eq(90)
        expect(receipt.reload.total_amount).to eq(90)
      end
    end
  end
end
