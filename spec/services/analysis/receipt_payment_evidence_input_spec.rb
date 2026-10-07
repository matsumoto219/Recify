require 'rails_helper'

RSpec.describe Analysis do
  it '決済欄の見出しがなく未分類の別支払があれば現金分だけを購入合計にしない' do
    params = described_class.build_receipt_params(
      ocr_result: {
        lines: [ 'お預り 1000円', '釣銭 400円', 'StarPay支払 400円' ],
        candidates: { total_amount: 1000, country_region: 'JPN', payment_method_text: '現金', items: [], payments: [] }
      }
    )

    expect(params.dig(:receipt_attributes, :total_amount)).to eq(1000)
    expect(params.dig(:amount_hints, :settlement_total_from_deposit_change)).not_to be(true)
    expect(params[:independent_receipt_payments]).to eq([])
  end

  it '商品券のお預りと釣銭を現金精算の購入合計補完に使わない' do
    params = described_class.build_receipt_params(
      ocr_result: {
        lines: [ '合計 1000円', 'eGiftお預り 1200円', '釣銭 200円' ],
        candidates: { total_amount: 1200, country_region: 'JPN', payment_method_text: 'eGift', items: [], payments: [] }
      }
    )

    expect(params.dig(:receipt_attributes, :total_amount)).to eq(1200)
    expect(params[:receipt_payments_attributes]).not_to include(include(method: 'cash'))
    expect(params.dig(:amount_hints, :settlement_total_from_deposit_change)).not_to be(true)
    expect(params[:independent_receipt_payments]).to eq([])
  end

  it '未分類の決済行が残る集合を購入候補の支払一致へ渡さない' do
    params = described_class.build_receipt_params(
      ocr_result: {
        lines: [ '合計 864円', '現金支払 600円', '未分類決済 264円', '釣銭 0円' ],
        candidates: { total_amount: 864, country_region: 'JPN', items: [], payments: [] }
      }
    )

    expect(params[:receipt_payments_attributes]).to eq([ { method: '現金支払', amount: 600 } ])
    expect(params[:independent_receipt_payments]).to eq([])
    expect(params.dig(:payment_evidence, :settlement, :ambiguous)).to be(true)
    expect(params.dig(:receipt_attributes, :total_amount)).to eq(864)
  end

  it '同一sourceの印字額とstructured額が矛盾する場合は候補の根拠にしない' do
    params = described_class.build_receipt_params(
      ocr_result: {
        lines: [ '合計 864円', '現金支払 864円', '釣銭 0円' ],
        candidates: {
          total_amount: 864,
          country_region: 'JPN',
          items: [],
          payments: [ { method: 'Cash', amount: 900, method_source_line_index: 1, source_line_index: 1 } ]
        }
      }
    )

    expect(params[:independent_receipt_payments]).to eq([])
    expect(params.dig(:payment_evidence, :settlement, :ambiguous)).to be(true)
    expect(params.dig(:receipt_attributes, :total_amount)).to eq(864)
  end
end
