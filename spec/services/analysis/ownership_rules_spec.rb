require "rails_helper"

RSpec.describe Analysis::OwnershipRules do
  let(:profile) { ReceiptAnalysisProfiles.default }

  def classify(proposal, lines:, items: [], payments: [], tax_details: [])
    described_class.classify(
      proposal: proposal,
      lines: lines,
      items: items,
      payments: payments,
      tax_details: tax_details,
      profile: profile
    )
  end

  it "bagのitem-owned表記と明示的なbag feeを分離する" do
    item_decision = classify(
      { kind: "bag_fee", sign: "surcharge", amount: 3, source_text: "レジ袋中1枚 3円", source_line_index: 0 },
      lines: [ "レジ袋中1枚 3円" ],
      items: [ { raw_text: "レジ袋中1枚", line_total: 3 } ]
    )
    fee_decision = classify(
      { kind: "bag_fee", sign: "surcharge", amount: 10, source_text: "袋代 10円", source_line_index: 0 },
      lines: [ "袋代 10円" ],
      items: [ { raw_text: "袋代", line_total: 10 } ]
    )
    invalid_sign_decision = classify(
      { kind: "bag_fee", sign: "discount", amount: 10, source_text: "袋代 10円", source_line_index: 0 },
      lines: [ "袋代 10円" ]
    )

    aggregate_failures do
      expect(item_decision).to have_attributes(owner: :item, action: :reject_false_positive)
      expect(fee_decision).to have_attributes(
        owner: :receipt_adjustment,
        fact_type: :purchase_adjustment,
        effect_scope: :purchase_total,
        kind: "bag_fee",
        sign: "surcharge",
        action: :persist
      )
      expect(invalid_sign_decision).to have_attributes(owner: :review_only, action: :review_only, review_required: true)
    end
  end

  it "item discountとreceipt couponをsource scopeで分離する" do
    item_decision = classify(
      { kind: "receipt_discount", sign: "discount", amount: 300, source_text: "割引", source_line_index: 2 },
      lines: [ "商品A 600円", "2個 50%", "割引 -300円", "小計 300円" ],
      items: [ { raw_text: "商品A", original_line_total: 600, discount_amount: 300, line_total: 300 } ]
    )
    coupon_decision = classify(
      { kind: "coupon", sign: "discount", amount: 100, source_text: "クーポン値引 -100円", source_line_index: 1 },
      lines: [ "小計 1,000円", "クーポン値引 -100円", "合計 900円" ],
      items: [ { raw_text: "商品A", line_total: 1_000 } ]
    )

    aggregate_failures do
      expect(item_decision).to have_attributes(owner: :item, action: :reject_false_positive)
      expect(coupon_decision).to have_attributes(
        owner: :receipt_adjustment,
        effect_scope: :purchase_total,
        kind: "coupon",
        action: :persist
      )
    end
  end

  it "point usageとcashless rewardをfinal payment側へ分類する" do
    point_decision = classify(
      { kind: "point_usage", sign: "discount", amount: 100, source_text: "ポイント利用 -100円", source_line_index: 0 },
      lines: [ "ポイント利用 -100円" ]
    )
    reward_decision = classify(
      { kind: "receipt_discount", sign: "discount", amount: 22, source_text: "キャッシュレス還元額 -22円", source_line_index: 0 },
      lines: [ "キャッシュレス還元額 -22円" ]
    )
    informational_decision = classify(
      { kind: "point_usage", sign: "discount", amount: 500, source_text: "保有ポイント 500P", source_line_index: 0 },
      lines: [ "保有ポイント 500P" ]
    )

    aggregate_failures do
      expect(point_decision).to have_attributes(owner: :receipt_adjustment, effect_scope: :final_payment_total, kind: "point_usage")
      expect(reward_decision).to have_attributes(owner: :receipt_adjustment, effect_scope: :final_payment_total)
      expect(informational_decision).to have_attributes(owner: :informational, action: :reject_false_positive)
    end
  end

  it "voucher・payment・tax detailをpurchase adjustmentにしない" do
    voucher_decision = classify(
      { kind: "coupon", sign: "discount", amount: 500, source_text: "ギフトカード 500円", source_line_index: 0 },
      lines: [ "ギフトカード 500円" ]
    )
    payment_decision = classify(
      { kind: "coupon", sign: "discount", amount: 900, source_text: "クレジット支払 900円", source_line_index: 0 },
      lines: [ "クレジット支払 900円" ],
      payments: [ { method: "credit_card", amount: 900 } ]
    )
    tax_decision = classify(
      { kind: "coupon", sign: "discount", amount: 9, source_text: "10%対象 91円 税 9円", source_line_index: 0 },
      lines: [ "10%対象 91円 税 9円" ],
      tax_details: [ { rate: 0.1, net_amount: 91, amount: 9 } ]
    )

    aggregate_failures do
      expect(voucher_decision).to have_attributes(owner: :payment, action: :convert_owner)
      expect(payment_decision).to have_attributes(owner: :payment, action: :reject_false_positive)
      expect(tax_decision).to have_attributes(owner: :tax_detail, action: :reject_false_positive)
    end
  end

  it "商品として販売されたgift cardと根拠のないpoint proposalを支払側へ移さない" do
    gift_card_item = classify(
      { kind: "coupon", sign: "discount", amount: 500, source_text: "Gift Card 500円", source_line_index: 0 },
      lines: [ "Gift Card 500円" ],
      items: [ { raw_text: "Gift Card", line_total: 500 } ]
    )
    unsupported_point = classify(
      { kind: "point_usage", sign: "discount", amount: 100, source_text: "商品A 100円", source_line_index: 0 },
      lines: [ "商品A 100円" ],
      items: [ { raw_text: "商品A", line_total: 100 } ]
    )

    aggregate_failures do
      expect(gift_card_item).to have_attributes(owner: :item, action: :reject_false_positive)
      expect(unsupported_point).to have_attributes(owner: :item, action: :reject_false_positive)
    end
  end

  it "cashless rewardが支払行と同額でもpayment adjustmentとして扱う" do
    decision = classify(
      {
        kind: "receipt_discount",
        sign: "discount",
        amount: 100,
        source_text: "キャッシュレス還元 -100円",
        source_line_index: 1
      },
      lines: [ "お支払い方法", "キャッシュレス還元 -100円" ],
      payments: [ { method: "e_money", amount: 100 } ]
    )

    expect(decision).to have_attributes(
      owner: :receipt_adjustment,
      fact_type: :payment_adjustment,
      effect_scope: :final_payment_total,
      action: :persist
    )
  end

  it "return/refundをpurchase adjustmentへ分類する" do
    decision = classify(
      { kind: "other", sign: "discount", amount: 980, source_text: "返品 商品A -980円", source_line_index: 0 },
      lines: [ "返品 商品A -980円" ]
    )

    expect(decision).to have_attributes(
      owner: :receipt_adjustment,
      fact_type: :purchase_adjustment,
      effect_scope: :purchase_total,
      kind: "return_refund",
      sign: "discount",
      action: :persist
    )
  end
end
