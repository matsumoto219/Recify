require 'rails_helper'

RSpec.describe Analysis::ReceiptPaymentAllocation do
  let(:amount_result) do
    ReceiptAmountService.call(
      receipt: { subtotal_amount: 800, tax_amount: 64, total_amount: 864 },
      receipt_items: [ { price: 800, quantity: 1, line_total: 800, tax_rate: BigDecimal('0.08') } ],
      receipt_tax_details: [ { description: '外税8%', rate: BigDecimal('0.08'), net_amount: 800, amount: 64 } ],
      context: :analysis
    )
  end
  let(:gift_evidence) do
    [ 600, 400 ].map.with_index do |amount, index|
      {
        method: 'eGift',
        amount: nil,
        printed_amount: amount,
        amount_role: 'voucher_tender',
        method_identity: 'other',
        settlement_method_key: 'egift',
        settlement_use: true,
        source_line_index: index + 5,
        source_span_start: 8,
        source_span_end: 11
      }
    end
  end
  let(:params) do
    {
      receipt_attributes: { total_amount: 864, payment_method: 'other' },
      receipt_payments_attributes: gift_evidence.map { |payment| payment.slice(:method, :amount) },
      payment_evidence: {
        payments: gift_evidence,
        settlement: { bounded: true, complete: true, ambiguous: false, gift_tender_method_keys: [ 'egift' ] }
      }
    }
  end

  it '確定した最終額へ商品券を1件の実充当額として配賦し元の印字証拠を保持する' do
    result = described_class.call(params:, amount_result:)

    aggregate_failures do
      expect(result[:receipt_payments_attributes]).to eq([ { method: 'eGift', amount: 864 } ])
      expect(result[:payment_evidence]).to eq(params[:payment_evidence])
      expect(result[:receipt_attributes]).to eq(params[:receipt_attributes])
      expect(params[:receipt_payments_attributes]).to all(include(amount: nil))
    end
  end

  it '複数の確定済み支払をすべて差し引き支払調整後の額を一度だけ使う' do
    amount_result[:computed][:payment_adjustment_total] = -64
    amount_result[:computed][:final_payment_total] = 800
    amount_result[:amount_engine][:selected_candidate][:final_payment_total] = 800
    params[:payment_evidence][:payments] += [
      { method: 'cash', amount: 150, amount_role: 'applied', method_identity: 'cash' },
      { method: 'credit_card', amount: 250, amount_role: 'applied', method_identity: 'credit_card' }
    ]
    result = described_class.call(params:, amount_result:)

    expect(result[:receipt_payments_attributes]).to eq([
      { method: 'eGift', amount: 400 }, { method: 'cash', amount: 150 }, { method: 'credit_card', amount: 250 }
    ])
  end

  it '方法だけが確定していても精算欄の完全性がない場合は残額を割り当てない' do
    params[:payment_evidence][:settlement][:complete] = false

    expect(described_class.call(params:, amount_result:)[:receipt_payments_attributes]).to all(include(amount: nil))
  end

  it '返金・割引・未分類行の競合を精算一致で打ち消さない' do
    params[:payment_evidence][:settlement][:ambiguous] = true

    expect(described_class.call(params:, amount_result:)[:receipt_payments_attributes]).to eq(params[:receipt_payments_attributes])
  end

  it '別支払の額が不明なら残額を商品券へ押し付けない' do
    params[:payment_evidence][:payments] << { method: 'cash', amount: nil, amount_role: 'unknown', method_identity: 'cash' }

    expect(described_class.call(params:, amount_result:)[:payment_allocation][:status]).to eq('unresolved')
  end

  it 'otherに分類された異なる商品券の残額帰属を一意としない' do
    params[:payment_evidence][:payments].last[:settlement_method_key] = 'storecredit'
    params[:payment_evidence][:settlement][:gift_tender_method_keys] << 'storecredit'

    expect(described_class.call(params:, amount_result:)[:receipt_payments_attributes]).to all(include(amount: nil))
  end

  it '肯定的な利用根拠のない額面だけから配賦しない' do
    params[:payment_evidence][:payments].first[:settlement_use] = false

    expect(described_class.call(params:, amount_result:)[:payment_allocation][:status]).to eq('unresolved')
  end

  it '印字額面合計を超える残額を配賦しない' do
    params[:payment_evidence][:payments].each { |payment| payment[:printed_amount] = 100 }

    expect(described_class.call(params:, amount_result:)[:payment_allocation][:status]).to eq('unresolved')
  end

  it '購入候補がrejectされている場合は残額を配賦しない' do
    amount_result[:selected_candidate_status] = 'rejected'

    expect(described_class.call(params:, amount_result:)[:payment_allocation][:status]).to eq('unresolved')
  end

  it '支払調整後の基準額が最終候補と矛盾する場合は配賦しない' do
    amount_result[:computed][:final_payment_total] = 865

    expect(described_class.call(params:, amount_result:)[:payment_allocation][:status]).to eq('unresolved')
  end

  it '確定済みの他支払が基準額を超えても負の充当額を作らない' do
    params[:payment_evidence][:payments] << { method: 'cash', amount: 900, amount_role: 'applied', method_identity: 'cash' }

    expect(described_class.call(params:, amount_result:)[:payment_allocation][:status]).to eq('unresolved')
  end
end
