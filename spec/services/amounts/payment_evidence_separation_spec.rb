require 'rails_helper'

RSpec.describe ReceiptAmountService do
  def differing_purchase_result
    {
      context: :edit_save,
      computed: { purchase_total: 1_000, payment_adjustment_total: -50, final_payment_total: 950 },
      resolved: { total: 800 },
      selected_candidate_status: 'accepted',
      amount_engine: { no_safe_candidate: false, selected_candidate: { purchase_total: 1_000, final_payment_total: 950 } },
      review_reasons: [ 'tax_detail_mismatch' ],
      inconsistencies: [ :tax_detail_mismatch ],
      blocking_inconsistencies: [ :tax_detail_mismatch ]
    }
  end

  let(:input) do
    {
      receipt: { subtotal_amount: 800, tax_amount: 64, total_amount: 864 },
      receipt_items: [ { price: 800, quantity: 1, line_total: 800, tax_rate: BigDecimal('0.08') } ],
      receipt_tax_details: [ { description: '外税8%', rate: BigDecimal('0.08'), net_amount: 800, amount: 64 } ],
      context: :analysis
    }
  end

  it '後段照合はcomputed購入額ではなくresolved購入額に支払調整を一度だけ適用する' do
    source = differing_purchase_result
    result = described_class.apply_payment_reconciliation(
      amount_result: source,
      receipt_payments: [ { method: 'credit_card', amount: 750 } ]
    )

    aggregate_failures do
      expect(result[:payment_reconciliation]).to include(
        purchase_total: 800,
        payment_adjustment_total: -50,
        final_payment_total: 750,
        payment_delta: 0,
        matched: true
      )
      expect(result[:review_reasons]).to eq([ 'tax_detail_mismatch' ])
      expect(result[:computed]).to eq(source[:computed])
      expect(result[:amount_engine]).to eq(source[:amount_engine])
    end
  end

  it 'Finalizeが保存する購入額を明示した場合はresolvedと異なってもその額で後段照合する' do
    source = differing_purchase_result
    result = described_class.apply_payment_reconciliation(
      amount_result: source,
      receipt_payments: [ { method: 'credit_card', amount: 550 } ],
      purchase_total: 600
    )

    aggregate_failures do
      expect(result[:payment_reconciliation]).to include(purchase_total: 600, final_payment_total: 550, payment_delta: 0, matched: true)
      expect(result[:computed]).to eq(source[:computed])
      expect(result[:resolved]).to eq(source[:resolved])
      expect(result[:amount_engine]).to eq(source[:amount_engine])
      expect(result[:review_reasons]).to eq([ 'tax_detail_mismatch' ])
    end
  end

  [ nil, 0 ].each do |purchase_total|
    it "明示した保存購入額#{purchase_total.inspect}をresolvedの既知額やcomputedへ戻さない" do
      source = differing_purchase_result.merge(review_reasons: [], inconsistencies: [], blocking_inconsistencies: [])
      source[:computed][:payment_adjustment_total] = 0
      result = described_class.apply_payment_reconciliation(
        amount_result: source,
        receipt_payments: [ { method: 'credit_card', amount: 0 } ],
        purchase_total: purchase_total
      )

      aggregate_failures do
        expect(result.dig(:payment_reconciliation, :final_payment_total)).to eq(purchase_total)
        expect(result.dig(:payment_reconciliation, :matched)).to eq(purchase_total.nil? ? nil : true)
        expect(result[:safe_to_auto_complete]).to eq(!purchase_total.nil?)
        expect(result[:computed]).to eq(source[:computed])
      end
    end
  end

  it 'computed購入額がない旧stub結果は明示保存額があっても書き換えない' do
    source = { resolved: { total: 800 }, review_reasons: [ 'payment_amount_mismatch' ], needs_review: true }
    result = described_class.apply_payment_reconciliation(
      amount_result: source,
      receipt_payments: [ { method: 'credit_card', amount: 600 } ],
      purchase_total: 600
    )

    expect(result).to eq(source)
  end

  it '購入合計が欠損した結果の内部0円を支払差額の基準にしない' do
    result = described_class.call(
      receipt: {},
      receipt_items: [],
      receipt_tax_details: [],
      receipt_payments: [ { method: 'cash', amount: 200 } ],
      context: :manual
    )

    expect(result.dig(:resolved, :total)).to be_nil
    expect(result[:payment_reconciliation]).to include(
      payment_amount_sum: 200,
      final_payment_total: nil,
      payment_delta: nil,
      matched: nil
    )
  end

  it '保存済みAR支払をanalysisでも印字証拠へ戻さず後段で照合する' do
    baseline = described_class.call(**input)
    payment = create(:receipt).receipt_payments.create!(method: 'credit_card', amount: 900)
    result = described_class.call(**input, receipt_payments: [ payment ])

    expect(result[:amount_engine]).to eq(baseline[:amount_engine])
    expect(result.dig(:payment_reconciliation, :payment_amount_sum)).to eq(900)
    expect(result[:review_reasons]).to include('payment_amount_mismatch')
  end

  it '保存済み支払のattributes Hashも購入候補の根拠にしない' do
    baseline = described_class.call(**input)
    payment = create(:receipt).receipt_payments.create!(method: 'credit_card', amount: 900)
    result = described_class.call(**input, receipt_payments: [ payment.attributes ])

    expect(result[:amount_engine]).to eq(baseline[:amount_engine])
    expect(result.dig(:payment_reconciliation, :payment_amount_sum)).to eq(900)
  end

  it '保存済み現金行の不一致をOCRのお預りとして抑制しない' do
    payment = create(:receipt).receipt_payments.create!(method: 'cash', amount: 900)
    result = described_class.call(**input, receipt_payments: [ payment ])

    expect(result[:review_reasons]).to include('payment_amount_mismatch')
    expect(result.dig(:payment_reconciliation, :matched)).to be(false)
  end

  it '額面と合計由来の支払額は購入候補・順位・reject判定へ入れない' do
    baseline = described_class.call(**input)
    result = described_class.call(
      **input,
      receipt_payments: [
        { method: 'eGift', amount: 1_000, amount_role: 'voucher_tender' },
        { method: 'cash', amount: 864, amount_role: 'allocated' }
      ]
    )

    aggregate_failures do
      expect(result[:resolved]).to eq(baseline[:resolved])
      expect(result[:amount_engine]).to eq(baseline[:amount_engine])
      expect(result.dig(:computed, :payment_amount_sum)).to be_nil
    end
  end

  it '保存済み支払額は編集時の購入候補を正当化せず後段で照合する' do
    baseline = described_class.call(**input.merge(context: :edit_save))
    result = described_class.call(**input.merge(context: :edit_save), receipt_payments: [ { method: 'cash', amount: 999 } ])

    aggregate_failures do
      expect(result[:resolved]).to eq(baseline[:resolved])
      expect(result[:amount_engine]).to eq(baseline[:amount_engine])
      expect(result[:review_reasons]).to include('payment_amount_mismatch')
      expect(result.dig(:payment_reconciliation, :payment_amount_sum)).to eq(999)
    end
  end

  it '後段の支払一致で税・明細の確認理由や候補の印字診断を消さない' do
    baseline = described_class.call(**input)
    baseline[:review_reasons] |= [ 'item_total_mismatch', 'tax_detail_mismatch' ]
    baseline[:blocking_inconsistencies] |= [ :item_total_mismatch, :tax_detail_mismatch ]
    baseline[:inconsistencies] |= [ :item_total_mismatch, :tax_detail_mismatch ]
    baseline[:needs_review] = true
    result = described_class.apply_payment_reconciliation(
      amount_result: baseline,
      receipt_payments: [ { method: 'eGift', amount: 864 } ]
    )

    aggregate_failures do
      expect(result[:review_reasons]).to include('item_total_mismatch', 'tax_detail_mismatch')
      expect(result[:needs_review]).to be(true)
      expect(result[:amount_engine]).to eq(baseline[:amount_engine])
      expect(result.dig(:computed, :payment_amount_sum)).to eq(baseline.dig(:computed, :payment_amount_sum))
      expect(result.dig(:payment_reconciliation, :matched)).to be(true)
    end
  end
end
