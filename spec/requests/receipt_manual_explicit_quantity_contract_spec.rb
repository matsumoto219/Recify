require 'rails_helper'

RSpec.describe 'Manual explicit quantity contract', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def explicit_item(quantity:, name: 'explicit quantity商品')
    {
      confirmed_name: name,
      pricing_source_kind: 'explicit_line_total',
      quantity: quantity,
      quantity_unit_code: 'kilogram',
      original_line_total: '250',
      line_total: '250',
      tax_rate: '0'
    }
  end

  def post_explicit_receipt(quantity:, name: 'explicit quantity商品')
    post receipts_path, params: {
      receipt: {
        store_name: "explicit quantity #{quantity.inspect}",
        payment_method: 'cash',
        receipt_items_attributes: {
          '0' => explicit_item(quantity: quantity, name: name)
        }
      }
    }
  end

  def rendered_quantity(name)
    document = Nokogiri::HTML(response.body)
    row = document.css('[data-receipt-form-target="itemRow"]').find do |candidate|
      candidate.at_css("input[name$='[confirmed_name]']")&.[]('value') == name
    end

    row&.at_css('[data-receipt-form-target="quantityInput"]')&.[]('value')
  end

  [ '', '1.2345' ].each do |quantity|
    it "meaningful explicit rowのquantity #{quantity.inspect}を422にしてraw入力を保持する" do
      expect do
        post_explicit_receipt(quantity: quantity)
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(rendered_quantity('explicit quantity商品')).to eq(quantity)
      end
    end
  end

  it 'scale 3と末尾0のみの追加precisionを丸めず保存する' do
    [ '1.234', '1.2300' ].each do |quantity|
      expect do
        post_explicit_receipt(quantity: quantity, name: "quantity #{quantity}")
      end.to change(Receipt, :count).by(1)

      item = user.receipts.order(:id).last.receipt_items.sole
      aggregate_failures quantity do
        expect(response).to redirect_to(receipts_path)
        expect(item.quantity).to eq(BigDecimal(quantity))
      end
    end
  end

  it 'existing explicit rowのpartial updateで未送信quantityを保持する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: 'partial explicit店',
      payment_method: 'cash',
      subtotal_amount: 250,
      tax_amount: 0,
      total_amount: 250,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '変更前',
      pricing_source_kind: 'explicit_line_total',
      quantity: BigDecimal('1.234'),
      quantity_unit_code: 'kilogram',
      original_line_total: 250,
      line_total: 250,
      tax_rate: BigDecimal('0'),
      needs_review: false,
      review_reasons: []
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '変更後' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload).to have_attributes(
        confirmed_name: '変更後',
        quantity: BigDecimal('1.234')
      )
    end
  end

  [ '', '1.2345' ].each do |quantity|
    it "existing explicit rowのquantity #{quantity.inspect}を422にしてrawとDBを保持する" do
      receipt = create(
        :receipt,
        user: user,
        status: 'completed',
        store_name: 'invalid explicit update店',
        payment_method: 'cash',
        subtotal_amount: 250,
        tax_amount: 0,
        total_amount: 250,
        review_reasons: []
      )
      item = receipt.receipt_items.create!(
        confirmed_name: 'invalid update商品',
        pricing_source_kind: 'explicit_line_total',
        quantity: BigDecimal('1.234'),
        quantity_unit_code: 'kilogram',
        original_line_total: 250,
        line_total: 250,
        tax_rate: BigDecimal('0'),
        needs_review: false,
        review_reasons: []
      )
      before = item.attributes.deep_dup

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: receipt.lock_version,
          receipt_items_attributes: {
            '0' => explicit_item(quantity: quantity, name: item.confirmed_name).merge(id: item.id)
          }
        }
      }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(rendered_quantity(item.confirmed_name)).to eq(quantity)
        expect(item.reload.attributes).to eq(before)
      end
    end
  end
end
