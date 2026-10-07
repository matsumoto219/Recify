require 'rails_helper'

RSpec.describe 'Receipt edit tax detail diagnostic', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def analyzed_ocr_result(basis)
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    result = Ocr::ResponseParser.new(response: raw, provider: :fixture).call
    candidates = result.fetch(:candidates)

    case basis
    when 'printed_tax_details_gross'
      candidates.merge!(
        subtotal_amount: 700,
        tax_amount: 70,
        total_amount: 770,
        tax_rate: BigDecimal('0.1'),
        tax_details: [ { description: '10%対象', net_amount: 770, amount: 70, rate: BigDecimal('0.1') } ],
        payments: []
      )
    when 'printed_tax_details_net'
      candidates.fetch(:items).slice!(2, 2)
      candidates.fetch(:item_calculation_mode_candidates).slice!(2, 2)
      candidates.merge!(
        subtotal_amount: 320,
        tax_amount: 32,
        total_amount: 352,
        tax_rate: BigDecimal('0.1'),
        tax_details: [ { description: '内税10%', net_amount: 320, amount: 32, rate: BigDecimal('0.1') } ],
        payments: []
      )
    when 'external_tax_from_receipt'
      candidates.merge!(
        subtotal_amount: 770,
        tax_amount: 77,
        total_amount: 847,
        tax_rate: BigDecimal('0.1'),
        tax_details: [ { description: '外税10%', net_amount: 770, amount: 77, rate: BigDecimal('0.1') } ],
        payments: []
      )
    else
      raise ArgumentError, 'unknown tax detail basis'
    end

    candidates.fetch(:items).each { |item| item[:tax_rate] = BigDecimal('0.1') }
    result
  end

  def finalized_receipt(basis)
    receipt = create(:receipt, :processing, :with_image, user:, country_region: 'JPN')
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, analyzed_ocr_result(basis))
    decision = Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: 'ocr_only',
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
    Receipts::Processing.record_finalize_decision(run, decision)

    result = Receipts::Processing.run_finalize(run.reload)
    expect(result.next_step).to eq(:done)
    receipt.reload
  end

  def stored_receipt(settings:)
    receipt = create(
      :receipt,
      :completed,
      user:,
      subtotal_amount: 200,
      tax_amount: 20,
      total_amount: 220,
      tax_rate: BigDecimal('0.1'),
      calculation_settings: settings
    )
    receipt.receipt_items.create!(
      confirmed_name: '確認品',
      price: 100,
      quantity: 2,
      quantity_unit_code: 'each',
      pricing_source_kind: 'count_unit_price',
      input_tax_inclusion: 'net',
      tax_inclusion_origin: 'manual',
      original_line_total: 200,
      line_total: 200,
      gross_line_total: 220,
      tax_rate: BigDecimal('0.1')
    )
    receipt.receipt_tax_details.create!(
      description: '外税10%',
      net_amount: 200,
      amount: 20,
      rate: BigDecimal('0.1')
    )
    receipt
  end

  def complete_settings
    {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'analysis' },
      'discount_rounding_mode' => { 'value' => 'floor', 'origin' => 'analysis' },
      'tax_rounding_scope' => { 'value' => 'per_tax_rate_group', 'origin' => 'analysis' }
    }
  end

  it '解析保存された税区分未確定のcount明細と税詳細を変更せず編集画面を開く' do
    receipt = finalized_receipt('printed_tax_details_net')
    items = receipt.receipt_items.order(:position_index).to_a
    receipt_values = receipt.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount', 'calculation_settings')
    item_values = items.map do |item|
      item.attributes.slice('input_tax_inclusion', 'tax_inclusion_origin', 'gross_line_total', 'price', 'line_total')
    end

    expect(receipt.amount_calculation_profile.dig('amount_engine', 'selected_basis')).to eq('printed_tax_details_net')
    expect(receipt.calculation_settings).to be_present
    expect(items).to all(have_attributes(pricing_source_kind: 'count_unit_price', input_tax_inclusion: nil))

    get edit_receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    form = document.at_css('form[data-controller~="receipt-form"]')
    rendered_items = items.map do |item|
      form.css('[data-receipt-form-target="itemRow"]').find do |row|
        row.at_css('input[name$="[id]"]')&.[]('value') == item.id.to_s
      end
    end

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(form&.[]('data-receipt-form-tax-detail-diagnostic-state-value')).to eq('unavailable')
      expect(rendered_items).to all(be_present)
      expect(rendered_items).to all(satisfy { |row| row['data-receipt-form-tax-inclusion-fallback'] == 'true' })
      expect(receipt.reload.attributes.slice(*receipt_values.keys)).to eq(receipt_values)
      expect(receipt.receipt_items.order(:position_index).map do |item|
        item.attributes.slice(*item_values.first.keys)
      end).to eq(item_values)
    end
  end

  [ 'printed_tax_details_gross', 'external_tax_from_receipt' ].each do |basis|
    it "#{basis}で解析保存された税区分未確定の明細も編集画面を開く" do
      receipt = finalized_receipt(basis)
      items = receipt.receipt_items.order(:position_index).to_a

      expect(receipt.amount_calculation_profile.dig('amount_engine', 'selected_basis')).to eq(basis)
      expect(receipt.calculation_settings).to be_present
      expect(items).to all(have_attributes(pricing_source_kind: 'count_unit_price', input_tax_inclusion: nil))

      get edit_receipt_path(receipt)

      expect(response).to have_http_status(:ok)
      expect(receipt.reload.receipt_items.pluck(:input_tax_inclusion, :gross_line_total)).to all(eq([ nil, nil ]))
    end
  end

  it '丸め条件が部分保存された税詳細付きレシートを編集画面に表示する' do
    receipt = stored_receipt(
      settings: { 'schema_version' => 1, 'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'manual' } }
    )
    saved_settings = receipt.calculation_settings.deep_dup

    get edit_receipt_path(receipt)

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form[data-controller~="receipt-form"]')&.[](
      'data-receipt-form-tax-detail-diagnostic-state-value'
    )).to eq('unavailable')
    expect(receipt.reload.calculation_settings).to eq(saved_settings)
  end

  it '計算方式が未記録の保存済み明細を表示するとき初期税区分を確定根拠にしない' do
    receipt = stored_receipt(settings: complete_settings)
    item = receipt.receipt_items.sole
    item.update_columns(
      pricing_source_kind: nil,
      input_tax_inclusion: nil,
      gross_line_total: nil,
      tax_inclusion_origin: nil
    )

    get edit_receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    form = document.at_css('form[data-controller~="receipt-form"]')
    row = form&.at_css('[data-receipt-form-target="itemRow"]')
    expect(response).to have_http_status(:ok)
    expect(form&.[]('data-receipt-form-tax-detail-diagnostic-state-value')).to eq('unavailable')
    expect(row&.[]('data-receipt-form-tax-inclusion-fallback')).to eq('true')
    expect(item.reload.input_tax_inclusion).to be_nil
  end

  it '税詳細がない旧明細では診断対象外として従来のプレビューを維持する' do
    receipt = stored_receipt(settings: complete_settings)
    item = receipt.receipt_items.sole
    item.update_columns(input_tax_inclusion: nil, gross_line_total: nil, tax_inclusion_origin: nil)
    receipt.receipt_tax_details.delete_all

    get edit_receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    form = document.at_css('form[data-controller~="receipt-form"]')
    row = form&.at_css('[data-receipt-form-target="itemRow"]')
    expect(response).to have_http_status(:ok)
    expect(form&.[]('data-receipt-form-tax-detail-diagnostic-state-value')).to eq('not_applicable')
    expect(row&.[]('data-receipt-form-tax-inclusion-fallback')).to eq('false')
  end

  it '購入調整の税区分が未確定のレシートを表示し、金額変更は保存しない' do
    receipt = stored_receipt(settings: complete_settings)
    item = receipt.receipt_items.sole
    receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: '送料',
      amount: 11,
      sign: 'surcharge',
      tax_rate: BigDecimal('0.1'),
      source: 'manual'
    )
    receipt.update!(subtotal_amount: 211, total_amount: 231)

    get edit_receipt_path(receipt)
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form[data-controller~="receipt-form"]')&.[](
      'data-receipt-form-tax-detail-diagnostic-state-value'
    )).to eq('unavailable')

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => { id: item.id, quantity: '3' } }
      }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(item.reload.quantity).to eq(2)
    expect(receipt.reload.total_amount).to eq(231)
  end

  it '税区分未確定のレシートのメモ変更では金額と条件を維持する' do
    receipt = finalized_receipt('printed_tax_details_net')
    original_amounts = receipt.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount', 'calculation_settings')
    original_items = receipt.receipt_items.order(:position_index).map(&:attributes)

    patch receipt_path(receipt), params: { receipt: { memo: '確認済み', lock_version: receipt.lock_version } }

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.reload.memo).to eq('確認済み')
      expect(receipt.attributes.slice(*original_amounts.keys)).to eq(original_amounts)
      expect(receipt.receipt_items.order(:position_index).map(&:attributes)).to eq(original_items)
    end
  end

  it '税区分を空欄で送信した金額変更は422で入力と保存済み値を保持する' do
    receipt = finalized_receipt('printed_tax_details_net')
    item = receipt.receipt_items.order(:position_index).first
    original_values = item.attributes

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => { id: item.id, quantity: '3', input_tax_inclusion: '' } }
      }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(item.reload.attributes).to eq(original_values)
    document = Nokogiri::HTML(response.body)
    row = document.css('[data-receipt-form-target="itemRow"]').find do |item_row|
      item_row.at_css('input[name$="[id]"]')&.[]('value') == item.id.to_s
    end
    expect(row).to be_present
    expect(row.at_css('[data-receipt-form-target="quantityInput"]')&.[]('value')).to eq('3')
  end
end
