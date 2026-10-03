require 'rails_helper'

RSpec.describe 'Receipt gross reference amount display', type: :request do
  it '税込額と正式合計を分け、税込額不明の明細も保存金額を無印で表示する' do
    user = create(:user)
    receipt = create(:receipt, :completed, user: user, total_amount: 41, subtotal_amount: 38, tax_amount: 3)
    2.times do |index|
      receipt.receipt_items.create!(
        confirmed_name: "明細#{index}",
        price: 19,
        quantity: 1,
        quantity_unit_code: 'each',
        pricing_source_kind: 'count_unit_price',
        input_tax_inclusion: 'net',
        tax_inclusion_origin: 'manual',
        original_line_total: 19,
        line_total: 19,
        gross_line_total: 20,
        position_index: index
      )
    end
    receipt.receipt_items.create!(confirmed_name: '旧明細', line_total: 999, position_index: 2)
    sign_in user

    expect(ReceiptAmountService).not_to receive(:call)
    get receipt_path(receipt)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body)
      amounts = html.css('[data-receipt-item-gross-amount]')
      expect(amounts.map(&:text).map(&:squish)).to eq([ '税込 ¥20', '税込 ¥20', '¥999' ])
      expect(response.body).to include('保存された丸め単位で正式に集計した金額', '¥41', '税抜', '単価: ¥19')
      expect(response.body).not_to include('税込額未確定', 'translation missing')
      expect(html.at_css('[data-tip-target="panel"][hidden]').text).to include(I18n.t('receipts.show.official_total_note'))
      expect(html.css('[data-controller="tip"]')).not_to be_empty
      expect(receipt.receipt_items.order(:position_index).pluck(:line_total)).to eq([ 19, 19, 999 ])
    end
  end

  it '税込額不明のゼロ円は金額を表示し、金額自体がない場合と区別する' do
    user = create(:user)
    receipt = create(:receipt, :completed, user: user)
    receipt.receipt_items.create!(confirmed_name: '金額ゼロ', line_total: 0, position_index: 0)
    receipt.receipt_items.create!(confirmed_name: '金額なし', line_total: nil, position_index: 1)
    sign_in user

    expect(ReceiptAmountService).not_to receive(:call)
    get receipt_path(receipt)

    amounts = Nokogiri::HTML(response.body).css('[data-receipt-item-gross-amount]')
    expect(amounts.map(&:text).map(&:squish)).to eq([ '¥0', I18n.t('receipts.common.not_available') ])
    expect(amounts.map(&:text).join).not_to include('税込', '税抜')
  end
end
