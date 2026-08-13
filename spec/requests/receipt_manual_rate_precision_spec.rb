require 'rails_helper'

RSpec.describe 'Receipt manual rate precision', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def capture_presenter_arguments
    arguments = []
    allow(ReceiptFormPresenter).to receive(:new).and_wrap_original do |original, **kwargs|
      arguments << kwargs
      original.call(**kwargs)
    end
    arguments
  end

  def item_attributes(overrides = {})
    {
      confirmed_name: '精度確認商品',
      price: '52',
      quantity: '1',
      quantity_unit_code: 'each',
      pricing_source_kind: 'count_unit_price',
      discount_rate: '10.5',
      tax_rate: '10.55'
    }.merge(overrides)
  end

  def number_field_wrapper(input)
    input&.ancestors&.find { |node| node['data-controller'].to_s.split.include?('number-field') }
  end

  it 'tax rateのstepperは2桁を維持し、discount rateは1桁契約を維持する' do
    get new_receipt_path

    document = Nokogiri::HTML(response.body)
    item_row = document.at_css('[data-receipt-form-target="itemRow"]')
    adjustment_template = Nokogiri::HTML.fragment(
      document.at_css('template[data-receipt-form-target="adjustmentTemplate"]')&.inner_html.to_s
    )

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(number_field_wrapper(item_row.at_css('[data-receipt-form-target="discountRateInput"]'))&.[]('data-number-field-decimal-precision-value')).to eq('1')
      expect(number_field_wrapper(item_row.at_css('[data-receipt-form-target="taxRateInput"]'))&.[]('data-number-field-decimal-precision-value')).to eq('2')
      expect(number_field_wrapper(adjustment_template.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]'))&.[]('data-number-field-decimal-precision-value')).to eq('2')
      expect(number_field_wrapper(item_row.at_css('[data-receipt-form-target="discountRateInput"]'))&.[]('data-number-field-decimal-comma-value')).to eq('true')
      expect(number_field_wrapper(item_row.at_css('[data-receipt-form-target="taxRateInput"]'))&.[]('data-number-field-decimal-comma-value')).to eq('true')
      expect(number_field_wrapper(adjustment_template.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]'))&.[]('data-number-field-decimal-comma-value')).to eq('true')
    end
  end

  it '永続scaleを超えるdiscount rateを422で保持し、計算も保存もしない' do
    presenters = capture_presenter_arguments
    submitted = {
      store_name: '精度超過店',
      payment_method: 'cash',
      receipt_items_attributes: {
        '0' => item_attributes(discount_rate: '10.55')
      },
      receipt_adjustments_attributes: {
        '0' => {
          kind: 'coupon',
          label: '精度超過クーポン',
          amount: '1',
          sign: 'discount',
          tax_rate: '10.55'
        }
      }
    }

    expect(ReceiptAmountService).not_to receive(:call)
    expect do
      post receipts_path, params: { receipt: submitted }
    end.not_to change(Receipt, :count)

    presented = presenters.last.fetch(:submitted_params).to_h
    document = Nokogiri::HTML(response.body)
    item_row = document.css('[data-receipt-form-target="itemRow"]').find do |row|
      row.at_css("input[name$='[confirmed_name]']")&.[]('value') == '精度確認商品'
    end
    adjustment_row = document.css('[data-receipt-form-target="adjustmentRow"]').find do |row|
      row.at_css("input[name$='[label]']")&.[]('value') == '精度超過クーポン'
    end

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presented.dig('receipt_items_attributes', '0', 'discount_rate')).to eq('10.55')
      expect(presented.dig('receipt_items_attributes', '0', 'tax_rate')).to eq('10.55')
      expect(presented.dig('receipt_adjustments_attributes', '0', 'tax_rate')).to eq('10.55')
      expect(item_row&.at_css('[data-receipt-form-target="discountRateInput"]')&.[]('value')).to eq('10.55')
      expect(item_row&.at_css('[data-receipt-form-target="taxRateInput"]')&.[]('value')).to eq('10.55')
      expect(adjustment_row&.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]')&.[]('value')).to eq('10.55')
    end
  end

  it '永続scaleを超えるitem tax rateを422で保持する' do
    presenters = capture_presenter_arguments

    expect(ReceiptAmountService).not_to receive(:call)
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '明細税率精度超過店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '税込178円商品',
              quantity: '1',
              quantity_unit_code: 'each',
              pricing_source_kind: 'explicit_line_total',
              original_line_total: '178',
              discount_rate: '',
              tax_rate: '10.555'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    presented = presenters.last.fetch(:submitted_params).to_h
    document = Nokogiri::HTML(response.body)
    item_row = document.css('[data-receipt-form-target="itemRow"]').find do |row|
      row.at_css("input[name$='[confirmed_name]']")&.[]('value') == '税込178円商品'
    end

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presented.dig('receipt_items_attributes', '0', 'tax_rate')).to eq('10.555')
      expect(item_row&.at_css('[data-receipt-form-target="taxRateInput"]')&.[]('value')).to eq('10.555')
      expect(item_row&.at_css('[data-receipt-form-target="explicitLineTotalInput"]')&.[]('value')).to eq('178')
    end
  end

  it '永続scaleを超えるadjustment tax rateを422で保持する' do
    presenters = capture_presenter_arguments

    expect(ReceiptAmountService).not_to receive(:call)
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '調整税率精度超過店',
          payment_method: 'cash',
          receipt_items_attributes: { '0' => item_attributes },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'coupon',
              label: '精度超過クーポン',
              amount: '1',
              sign: 'discount',
              tax_rate: '10.555'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    presented = presenters.last.fetch(:submitted_params).to_h
    document = Nokogiri::HTML(response.body)
    adjustment_row = document.css('[data-receipt-form-target="adjustmentRow"]').find do |row|
      row.at_css("input[name$='[label]']")&.[]('value') == '精度超過クーポン'
    end

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presented.dig('receipt_adjustments_attributes', '0', 'tax_rate')).to eq('10.555')
      expect(adjustment_row&.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]')&.[]('value')).to eq('10.555')
    end
  end

  it '永続scaleを超えるreceipt tax rateを422でrawのままPresenterへ渡す' do
    presenters = capture_presenter_arguments

    expect(ReceiptAmountService).not_to receive(:call)
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: 'レシート税率精度超過店',
          payment_method: 'cash',
          tax_rate: '0.10555',
          receipt_items_attributes: { '0' => item_attributes }
        }
      }
    end.not_to change(Receipt, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presenters.last.fetch(:submitted_params).to_h['tax_rate']).to eq('0.10555')
    end
  end

  it '永続scale境界のitemとadjustment rateを計算値と同じ値で保存する' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '精度境界店',
          payment_method: 'cash',
          receipt_items_attributes: { '0' => item_attributes },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'coupon',
              label: '精度境界クーポン',
              amount: '1',
              sign: 'discount',
              tax_rate: '10.55'
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    receipt = user.receipts.find_by!(store_name: '精度境界店')
    item = receipt.receipt_items.sole
    adjustment = receipt.receipt_adjustments.sole

    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(item).to have_attributes(
        original_line_total: 52,
        discount_rate: BigDecimal('0.105'),
        discount_amount: 5,
        line_total: 47,
        tax_rate: BigDecimal('0.1055')
      )
      expect(adjustment.tax_rate).to eq(BigDecimal('0.1055'))
      expect(receipt.tax_rate).to eq(BigDecimal('0.1055'))
      expect(receipt.receipt_tax_details.sole.rate).to eq(BigDecimal('0.1055'))
      expect(receipt.total_amount).to eq(46)
    end
  end
end
