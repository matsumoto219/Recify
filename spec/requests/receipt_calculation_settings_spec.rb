require 'rails_helper'

RSpec.describe 'Receipt calculation settings', type: :request do
  let(:user) { create(:user, default_item_tax_inclusion: 'net') }
  let(:settings) do
    {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'form_default' },
      'discount_rounding_mode' => { 'value' => 'round', 'origin' => 'form_default' },
      'tax_rounding_scope' => { 'value' => 'per_tax_rate_group', 'origin' => 'application_default' }
    }
  end

  before do
    LegalDocuments::Sync.call
    sign_in user
  end

  def context_for(receipt = Receipt.new(user: user))
    Receipts::CalculationContext.build(user: user, receipt: receipt).token
  end

  def count_item(**overrides)
    {
      confirmed_name: '入力商品',
      category: 'food',
      price: '100',
      quantity: '2',
      quantity_unit_code: 'each',
      pricing_source_kind: 'count_unit_price',
      tax_rate: '10',
      input_tax_inclusion: 'net'
    }.merge(overrides)
  end

  def create_parameters(item = count_item)
    {
      receipt_calculation_context: context_for,
      receipt: {
        store_name: '入力店舗',
        purchased_on: Date.current.iso8601,
        payment_method: 'cash',
        receipt_items_attributes: { '0' => item }
      }
    }
  end

  def stored_receipt
    receipt = create(
      :receipt,
      :completed,
      user: user,
      subtotal_amount: 200,
      tax_amount: 20,
      total_amount: 220,
      tax_rate: '0.1',
      calculation_settings: settings
    )
    receipt.receipt_items.create!(
      confirmed_name: '入力商品',
      category: 'food',
      price: 100,
      quantity: 2,
      quantity_unit_code: 'each',
      pricing_source_kind: 'count_unit_price',
      input_tax_inclusion: 'net',
      tax_inclusion_origin: 'form_default',
      tax_rate: '0.1',
      original_line_total: 200,
      line_total: 200,
      gross_line_total: 220
    )
    receipt
  end

  it 'フォーム開始時の初期値を署名contextに保持する' do
    get new_receipt_path

    document = Nokogiri::HTML(response.body)
    token = document.at_css('input[name="receipt_calculation_context"]')&.[]('value')
    result = Receipts::CalculationContext.verify(token: token, user: user, receipt: user.receipts.new)

    expect(response).to have_http_status(:success)
    expect(result&.default_for('default_item_tax_inclusion')).to eq('net')
  end

  it 'HEADでもGETと同じ初期値構築経路を使い保存しない' do
    expect(Receipts::CalculationContext).to receive(:build).with(user: user, receipt: an_instance_of(Receipt)).and_call_original
    expect(Receipts::CalculationContext).not_to receive(:verify)

    expect { head new_receipt_path }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:success)
    expect(response.body).to be_empty
  end

  it '税抜countのsourceと税込参考額を分離して保存する' do
    post receipts_path, params: create_parameters

    expect(response).to have_http_status(:redirect)
    receipt = user.receipts.order(:id).last
    item = receipt.receipt_items.sole
    aggregate_failures do
      expect(receipt).to have_attributes(subtotal_amount: 200, tax_amount: 20, total_amount: 220)
      expect(item).to have_attributes(price: 100, quantity: 2, line_total: 200, gross_line_total: 220)
      expect(item.input_tax_inclusion).to eq('net')
      expect(item.tax_inclusion_origin).to eq('form_default')
      expect(receipt.calculation_settings).to eq(settings)
    end
  end

  it 'explicit税抜額に数量を掛けず税込参考額を保存する' do
    item = count_item(pricing_source_kind: 'explicit_line_total', original_line_total: '500', quantity: '4')

    post receipts_path, params: create_parameters(item)

    expect(response).to have_http_status(:redirect)
    receipt = user.receipts.order(:id).last
    expect(receipt.total_amount).to eq(550)
    expect(receipt.receipt_items.sole).to have_attributes(original_line_total: 500, line_total: 500, gross_line_total: 550)
  end

  it '開始後のUser変更を進行中フォームの丸め条件へ適用しない' do
    parameters = create_parameters(count_item(price: '19', quantity: '1'))
    parameters[:receipt][:receipt_items_attributes]['1'] = count_item(price: '19', quantity: '1')
    user.update!(tax_rounding_mode: 'ceil', default_item_tax_inclusion: 'gross')

    post receipts_path, params: parameters

    expect(response).to have_http_status(:redirect)
    receipt = user.receipts.order(:id).last
    expect(receipt.total_amount).to eq(41)
    expect(receipt.receipt_items.map(&:gross_line_total)).to eq([ 20, 20 ])
    expect(receipt.calculation_settings.dig('tax_rounding_mode', 'value')).to eq('floor')
  end

  it 'contextも具体的な丸め条件もない新規入力は保存しない' do
    parameters = create_parameters
    parameters.delete(:receipt_calculation_context)

    expect { post receipts_path, params: parameters }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'メモだけのPATCHではAmountを再実行せず保存条件と金額を維持する' do
    receipt = stored_receipt
    before_values = receipt.attributes.slice('calculation_settings', 'amount_calculation_profile', 'total_amount', 'tax_amount')
    before_item = receipt.receipt_items.sole.attributes
    expect(ReceiptAmountService).not_to receive(:call)

    patch receipt_path(receipt), params: { receipt: { memo: '確認済み', lock_version: receipt.lock_version } }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.attributes.slice(*before_values.keys)).to eq(before_values)
    expect(receipt.receipt_items.sole.attributes).to eq(before_item)
  end

  it '同値の条件とsource再送では由来やprofileを作り直さない' do
    receipt = stored_receipt
    receipt.update!(status: 'review_needed', review_reasons: [ 'tax_detail_mismatch' ])
    item = receipt.receipt_items.sole
    before_values = receipt.attributes.slice('calculation_settings', 'amount_calculation_profile', 'total_amount')
    expect(ReceiptAmountService).not_to receive(:call)

    patch receipt_path(receipt), params: {
      receipt_calculation_context: context_for(receipt),
      receipt_calculation_settings: { tax_rounding_mode: 'floor', discount_rounding_mode: 'round' },
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => count_item(id: item.id) }
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.attributes.slice(*before_values.keys)).to eq(before_values)
    expect(item.reload.tax_inclusion_origin).to eq('form_default')
    expect(receipt).to have_attributes(status: 'review_needed', review_reasons: [ 'tax_detail_mismatch' ])
  end

  it '税区分切替で単価を自動換算しない' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole

    patch receipt_path(receipt), params: {
      receipt_calculation_context: context_for(receipt),
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => { id: item.id, input_tax_inclusion: 'gross' } }
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.total_amount).to eq(200)
    expect(item.reload).to have_attributes(price: 100, quantity: 2, line_total: 200, gross_line_total: 200)
    expect(item.tax_inclusion_origin).to eq('manual')
  end

  it '支払だけの変更は購入計算をせず保存済み合計と照合する' do
    receipt = stored_receipt
    receipt.update!(status: 'review_needed', review_reasons: %w[payment_amount_mismatch tax_detail_mismatch])
    payment = receipt.receipt_payments.create!(method: 'cash', amount: 200)
    before_values = receipt.attributes.slice('calculation_settings', 'amount_calculation_profile', 'total_amount', 'tax_amount')
    expect(ReceiptAmountService).not_to receive(:call)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_payments_attributes: { '0' => { id: payment.id, amount: 220 } }
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.attributes.slice(*before_values.keys)).to eq(before_values)
    expect(receipt.review_reasons).to include('tax_detail_mismatch')
    expect(receipt.review_reasons).not_to include('payment_amount_mismatch')
  end

  it '支払だけの変更でも不一致は確認対象にする' do
    receipt = stored_receipt
    expect(ReceiptAmountService).not_to receive(:call)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_payments_attributes: { '0' => { method: 'cash', amount: 200 } }
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.review_reasons).to include('payment_amount_mismatch')
    expect(receipt.status).to eq('review_needed')
    expect(receipt.total_amount).to eq(220)
  end

  [ nil, '', 'tax_excluded', 'NET', false, [ 'net' ], { value: 'net' } ].each do |value|
    it "不正な税区分#{value.inspect}を未送信と扱わない" do
      receipt = stored_receipt
      item = receipt.receipt_items.sole
      before_values = item.attributes

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: receipt.lock_version,
          receipt_items_attributes: { '0' => { id: item.id, input_tax_inclusion: value } }
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.attributes).to eq(before_values)
    end
  end

  it '署名なしでも必要な具体値が揃った手動入力は保存できる' do
    parameters = create_parameters
    parameters.delete(:receipt_calculation_context)
    parameters[:receipt_calculation_settings] = { tax_rounding_mode: 'floor', discount_rounding_mode: 'round' }

    post receipts_path, params: parameters

    expect(response).to have_http_status(:redirect)
    receipt = user.receipts.order(:id).last
    expect(receipt.total_amount).to eq(220)
    expect(receipt.calculation_settings.dig('tax_rounding_mode', 'origin')).to eq('manual')
    expect(receipt.receipt_items.sole.tax_inclusion_origin).to eq('manual')
  end

  it '明示的な非課税0を保持し未入力と区別する' do
    post receipts_path, params: create_parameters(count_item(tax_rate: '0'))

    expect(response).to have_http_status(:redirect)
    receipt = user.receipts.order(:id).last
    expect(receipt).to have_attributes(total_amount: 200, tax_amount: 0)
    expect(receipt.receipt_items.sole.tax_rate).to eq(0)
  end

  it '税抜入力で欠損税率を10パーセントへ補完しない' do
    parameters = create_parameters(count_item(tax_rate: ''))

    expect { post receipts_path, params: parameters }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it '丸め変更は未送信の全明細へ適用するが元金額を変更しない' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole
    item.update!(price: 19, quantity: 1, original_line_total: 19, line_total: 19, gross_line_total: 20)
    receipt.update!(subtotal_amount: 19, tax_amount: 1, total_amount: 20)

    patch receipt_path(receipt), params: {
      receipt_calculation_settings: { tax_rounding_mode: 'ceil' },
      receipt: { lock_version: receipt.lock_version }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload).to have_attributes(total_amount: 21, tax_amount: 2)
    expect(item.reload).to have_attributes(price: 19, line_total: 19, gross_line_total: 21)
  end

  it '既存レシートへの追加行だけがフォーム開始時の初期税区分を使う' do
    receipt = stored_receipt
    original = receipt.receipt_items.sole
    user.update!(default_item_tax_inclusion: 'gross')
    parameters = {
      receipt_calculation_context: context_for(receipt),
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => count_item(price: '22', quantity: '1').except(:input_tax_inclusion) }
      }
    }
    user.update!(default_item_tax_inclusion: 'net', tax_rounding_mode: 'ceil')

    patch receipt_path(receipt), params: parameters

    expect(response).to have_http_status(:redirect)
    expect(original.reload.input_tax_inclusion).to eq('net')
    added = receipt.receipt_items.order(:id).last
    expect(added.input_tax_inclusion).to eq('gross')
    expect(receipt.reload.total_amount).to eq(242)
    expect(receipt.calculation_settings.dig('tax_rounding_mode', 'value')).to eq('floor')
  end

  it '送料の税区分を明細切替に連動させない' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole
    receipt.update!(
      calculation_settings: settings.merge(
        'purchase_adjustment_tax_inclusion' => { 'value' => 'gross', 'origin' => 'manual' }
      ),
      total_amount: 231,
      subtotal_amount: 210,
      tax_amount: 21
    )
    receipt.receipt_adjustments.create!(kind: 'delivery_fee', label: '送料', amount: 11, sign: 'surcharge', tax_rate: '0.1', source: 'manual')

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => { id: item.id, input_tax_inclusion: 'gross' } }
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.total_amount).to eq(211)
    expect(receipt.calculation_settings.dig('purchase_adjustment_tax_inclusion', 'value')).to eq('gross')
    expect(receipt.receipt_adjustments.sole.amount).to eq(11)
  end

  it '旧購入調整の税区分が不明な場合は金額変更時だけ確認を求める' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole
    receipt.receipt_adjustments.create!(kind: 'delivery_fee', label: '送料', amount: 11, sign: 'surcharge', tax_rate: '0.1', source: 'manual')

    patch receipt_path(receipt), params: { receipt: { lock_version: receipt.lock_version, memo: 'メモのみ' } }
    expect(response).to have_http_status(:redirect)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.reload.lock_version,
        receipt_items_attributes: { '0' => { id: item.id, quantity: '3' } }
      }
    }
    expect(response).to have_http_status(:unprocessable_content)
    expect(item.reload.quantity).to eq(2)

    patch receipt_path(receipt), params: {
      receipt_calculation_settings: { purchase_adjustment_tax_inclusion: 'gross' },
      receipt: {
        lock_version: receipt.reload.lock_version,
        receipt_items_attributes: { '0' => { id: item.id, quantity: '3' } }
      }
    }
    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.total_amount).to eq(341)
  end

  it 'クライアントの保存用JSONと派生額をauthorityとして受け付けない' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        calculation_settings: { schema_version: 1, tax_rounding_mode: { value: 'ceil', origin: 'analysis' } },
        receipt_items_attributes: { '0' => { id: item.id, gross_line_total: 999, tax_inclusion_origin: 'analysis' } }
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(receipt.reload.calculation_settings).to eq(settings)
    expect(item.reload).to have_attributes(gross_line_total: 220, tax_inclusion_origin: 'form_default')
  end

  it '保存エラーでは元金額と条件を部分保存せず開始時contextを再表示する' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole
    token = context_for(receipt)
    before_receipt = receipt.attributes
    before_item = item.attributes
    user.update!(tax_rounding_mode: 'ceil', default_item_tax_inclusion: 'gross')

    patch receipt_path(receipt), params: {
      receipt_calculation_context: token,
      receipt_calculation_settings: { tax_rounding_mode: 'round' },
      receipt: {
        lock_version: receipt.lock_version,
        store_name: '',
        receipt_items_attributes: { '0' => { id: item.id, input_tax_inclusion: 'gross' } }
      }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(receipt.reload.attributes).to eq(before_receipt)
    expect(item.reload.attributes).to eq(before_item)
    document = Nokogiri::HTML(response.body)
    rendered_token = document.at_css('input[name="receipt_calculation_context"]')&.[]('value')
    expect(rendered_token).to eq(token)
    expect(
      Receipts::CalculationContext.verify(token: rendered_token, user: user, receipt: receipt)
        .default_for('default_item_tax_inclusion')
    ).to eq('net')
    expect(document.at_css('input[name="receipt_calculation_settings[tax_rounding_mode]"][checked]')&.[]('value')).to eq('round')
  end

  it '競合した金額変更では保存条件も税込参考額も上書きしない' do
    receipt = stored_receipt
    item = receipt.receipt_items.sole
    token = context_for(receipt)
    submitted_version = receipt.lock_version
    receipt.update!(memo: '別の編集')
    before_receipt = receipt.attributes
    before_item = item.attributes

    patch receipt_path(receipt), params: {
      receipt_calculation_context: token,
      receipt_calculation_settings: { tax_rounding_mode: 'ceil' },
      receipt: {
        lock_version: submitted_version,
        receipt_items_attributes: { '0' => { id: item.id, input_tax_inclusion: 'gross' } }
      }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(receipt.reload.attributes).to eq(before_receipt)
    expect(item.reload.attributes).to eq(before_item)
  end
end
