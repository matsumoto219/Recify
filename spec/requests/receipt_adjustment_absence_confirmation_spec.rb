require 'rails_helper'

RSpec.describe 'レシートの調整なし確認', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def create_review_receipt(review_reasons: [ 'adjustment_uncertain' ])
    receipt = create(
      :receipt,
      user: user,
      status: 'review_needed',
      review_reasons: review_reasons,
      store_name: '調整確認店',
      purchased_at: Time.zone.local(2026, 8, 10, 12, 0, 0),
      payment_method: 'cash',
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      tax_rate: 0
    )
    receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      tax_rate: 0,
      line_total: 100,
      needs_review: false,
      review_reasons: []
    )
    receipt
  end

  def update_params(receipt, **receipt_attributes)
    {
      receipt: {
        lock_version: receipt.lock_version,
        memo: '確認済み',
        **receipt_attributes
      }
    }
  end

  it 'receipt-level reasonがあり保存済み調整行がない編集画面へ確認操作を表示する' do
    receipt = create_review_receipt

    get edit_receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    panel = document.at_css('[data-receipt-adjustment-absence-confirmation]')
    checkbox = panel&.at_css('input[name="receipt_form_adjustment_absence_confirmed"]')

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(panel).to be_present
      expect(panel['hidden']).to be_nil
      expect(panel['inert']).to be_nil
      expect(panel['aria-hidden']).to eq('false')
      expect(panel['role']).to eq('group')
      expect(panel['aria-labelledby']).to eq('receipt-adjustment-absence-confirmation-title')
      expect(panel['aria-describedby']).to eq('receipt-adjustment-absence-confirmation-description')
      expect(panel.text).to include(
        '値引き・手数料の有無を確認してください',
        'レシート全体の値引き・手数料などはありません'
      )
      expect(checkbox).to be_present
      expect(checkbox['type']).to eq('checkbox')
      expect(checkbox['value']).to eq('1')
      expect(checkbox['checked']).to be_nil
    end
  end

  it 'reasonがない場合と保存済み調整行がある場合は確認操作を表示しない' do
    no_reason_receipt = create_review_receipt(review_reasons: [ 'ocr_unreadable' ])
    with_adjustment_receipt = create_review_receipt
    create(:receipt_adjustment, receipt: with_adjustment_receipt)

    get edit_receipt_path(no_reason_receipt)
    no_reason_document = Nokogiri::HTML(response.body)
    get edit_receipt_path(with_adjustment_receipt)
    with_adjustment_document = Nokogiri::HTML(response.body)

    aggregate_failures do
      expect(no_reason_document.at_css('[data-receipt-adjustment-absence-confirmation]')).to be_nil
      expect(with_adjustment_document.at_css('[data-receipt-adjustment-absence-confirmation]')).to be_nil
    end
  end

  it '通常保存と不正な確認値ではreasonを維持し、明示確認時だけ解除する' do
    receipt = create_review_receipt

    patch receipt_path(receipt), params: update_params(receipt)
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.status).to eq('review_needed')
      expect(receipt.review_reasons).to eq([ 'adjustment_uncertain' ])
    end

    patch receipt_path(receipt), params: update_params(receipt).merge(
      receipt_form_adjustment_absence_confirmed: 'true'
    )
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.status).to eq('review_needed')
      expect(receipt.review_reasons).to eq([ 'adjustment_uncertain' ])
    end

    patch receipt_path(receipt), params: update_params(receipt).merge(
      receipt_form_adjustment_absence_confirmed: '1'
    )
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.status).to eq('completed')
      expect(receipt.review_reasons).to be_empty
      expect(receipt.receipt_adjustments).to be_empty
    end
  end

  it '明示確認ではadjustment reasonだけを解除して他のblocking reasonを維持する' do
    receipt = create_review_receipt(review_reasons: %w[adjustment_uncertain ocr_unreadable])

    patch receipt_path(receipt), params: update_params(receipt).merge(
      receipt_form_adjustment_absence_confirmed: '1'
    )
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.status).to eq('review_needed')
      expect(receipt.review_reasons).to eq([ 'ocr_unreadable' ])
    end
  end

  it 'review stateの再構築対象外statusではcrafted確認値を無視する' do
    receipt = create_review_receipt
    receipt.update_columns(status: 'uploaded')

    patch receipt_path(receipt), params: update_params(receipt).merge(
      receipt_form_adjustment_absence_confirmed: '1'
    )
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.status).to eq('uploaded')
      expect(receipt.review_reasons).to eq([ 'adjustment_uncertain' ])
    end
  end

  it '保存失敗後は確認状態を保持し、stale conflictでは再確認を求める' do
    receipt = create_review_receipt

    patch receipt_path(receipt), params: update_params(receipt, total_amount: 'abc').merge(
      receipt_form_adjustment_absence_confirmed: '1'
    )
    invalid_document = Nokogiri::HTML(response.body)
    invalid_checkbox = invalid_document.at_css('input[name="receipt_form_adjustment_absence_confirmed"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(invalid_checkbox['checked']).to eq('checked')
      expect(receipt.reload.review_reasons).to eq([ 'adjustment_uncertain' ])
    end

    patch receipt_path(receipt), params: {
      receipt_form_adjustment_absence_confirmed: '1',
      receipt: {
        lock_version: receipt.lock_version - 1,
        memo: 'stale'
      }
    }
    stale_document = Nokogiri::HTML(response.body)
    stale_checkbox = stale_document.at_css('input[name="receipt_form_adjustment_absence_confirmed"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(stale_checkbox['checked']).to be_nil
      expect(receipt.reload.review_reasons).to eq([ 'adjustment_uncertain' ])
    end
  end

  it 'model validationによる422でも確認状態と保存済みreasonを保持する' do
    receipt = create_review_receipt

    patch receipt_path(receipt), params: update_params(receipt, store_name: '').merge(
      receipt_form_adjustment_absence_confirmed: '1'
    )
    document = Nokogiri::HTML(response.body)
    checkbox = document.at_css('input[name="receipt_form_adjustment_absence_confirmed"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(checkbox['checked']).to eq('checked')
      expect(receipt.reload.store_name).to eq('調整確認店')
      expect(receipt.review_reasons).to eq([ 'adjustment_uncertain' ])
    end
  end

  it '新規調整行を含む422では確認panelを非操作化して確認状態を解除する' do
    receipt = create_review_receipt

    patch receipt_path(receipt), params: update_params(
      receipt,
      total_amount: 'abc',
      receipt_adjustments_attributes: {
        '0' => { kind: 'coupon', label: '入力中クーポン', amount: '10', sign: 'discount' }
      }
    ).merge(receipt_form_adjustment_absence_confirmed: '1')
    document = Nokogiri::HTML(response.body)
    panel = document.at_css('[data-receipt-adjustment-absence-confirmation]')
    checkbox = panel.at_css('input[name="receipt_form_adjustment_absence_confirmed"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(panel['hidden']).to eq('')
      expect(panel['inert']).to eq('')
      expect(panel['aria-hidden']).to eq('true')
      expect(checkbox['checked']).to be_nil
      expect(receipt.reload.review_reasons).to eq([ 'adjustment_uncertain' ])
    end
  end
end
