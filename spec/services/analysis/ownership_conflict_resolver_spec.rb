require "rails_helper"

RSpec.describe Analysis::OwnershipConflictResolver do
  let(:profile) { ReceiptAnalysisProfiles.default }
  let(:money_pattern) { profile.analysis_adjustment_amount_candidate_pattern }

  def resolve(lines:, items: [], adjustments: [], payments: [], tax_details: [])
    Analysis::ReceiptFactOwnershipResolver.call(
      items: items,
      adjustments: adjustments,
      payments: payments,
      tax_details: tax_details,
      review_reasons: [],
      evidence_index: Analysis::SourceEvidenceIndex.call(
        lines: lines,
        money_pattern: money_pattern,
        profile: profile
      ),
      profile: profile
    )
  end

  it "明示的なsurchargeと同じsource money tokenを持つitemはadjustmentへ一本化する" do
    result = resolve(
      lines: [ "袋代 10円" ],
      items: [ { raw_text: "袋代", line_total: 10, tax_rate: 0.1 } ],
      adjustments: [
        {
          kind: "bag_fee",
          sign: "surcharge",
          amount: 10,
          source: "ai",
          source_text: "袋代 10円",
          source_line_index: 0
        }
      ]
    )

    aggregate_failures do
      expect(result.items).to eq([])
      expect(result.adjustments).to contain_exactly(include(kind: "bag_fee", amount: 10))
    end
  end

  it "item-owned sourceに対するadjustment proposalはitemだけを残す" do
    result = resolve(
      lines: [ "レジ袋中1枚 3円" ],
      items: [ { raw_text: "レジ袋中1枚", line_total: 3, tax_rate: 0.1 } ],
      adjustments: [
        {
          kind: "bag_fee",
          sign: "discount",
          amount: 3,
          source: "ai",
          source_text: "レジ袋中1枚 3円",
          source_line_index: 0
        }
      ]
    )

    aggregate_failures do
      expect(result.items).to contain_exactly(include(raw_text: "レジ袋中1枚", line_total: 3))
      expect(result.adjustments).to eq([])
    end
  end

  it "structured itemとAI proposalのproviderが異なっても同じphysical money tokenを競合解決する" do
    line = "レジ袋中1枚 3円"
    token = Analysis::SourceEvidenceIndex.call(
      lines: [ line ],
      money_pattern: money_pattern,
      profile: profile
    ).first[:tokens].find { |candidate| candidate[:kind] == :money }
    result = resolve(
      lines: [ line ],
      items: [
        {
          raw_text: "レジ袋中1枚",
          line_total: 3,
          tax_rate: 0.1,
          source_provider: "azure_structured",
          source_field_path: "documents[0].fields.Items[0].TotalPrice",
          source_line_index: 0,
          source_span_start: token[:span_start],
          source_span_end: token[:span_end]
        }
      ],
      adjustments: [
        {
          kind: "bag_fee",
          sign: "discount",
          amount: 3,
          source: "ai",
          source_text: line,
          source_line_index: 0
        }
      ]
    )

    aggregate_failures do
      expect(result.items).to contain_exactly(include(raw_text: "レジ袋中1枚", line_total: 3))
      expect(result.adjustments).to eq([])
      expect(result.facts.first.source_refs.first).to have_attributes(
        provider: :azure_structured,
        field_path: "documents[0].fields.Items[0].TotalPrice"
      )
    end
  end

  it "point usageが同じsource tokenのpaymentにもある場合はpayment adjustmentだけを残す" do
    result = resolve(
      lines: [ "ポイント利用 -100円" ],
      adjustments: [
        {
          kind: "point_usage",
          sign: "discount",
          amount: 100,
          source: "ocr",
          source_text: "ポイント利用 -100円",
          source_line_index: 0
        }
      ],
      payments: [
        { method: "ポイント利用", amount: 100, source_text: "ポイント利用 -100円", source_line_index: 0 }
      ]
    )

    aggregate_failures do
      expect(result.adjustments).to contain_exactly(include(kind: "point_usage", amount: 100))
      expect(result.payments).to eq([])
    end
  end

  it "voucher adjustmentをpaymentへ変換し同じsource paymentがあれば重複追加しない" do
    without_payment = resolve(
      lines: [ "Gift Card 500円" ],
      adjustments: [
        {
          kind: "coupon",
          sign: "discount",
          amount: 500,
          source: "ai",
          source_text: "Gift Card 500円",
          source_line_index: 0
        }
      ]
    )
    with_payment = resolve(
      lines: [ "Gift Card 500円" ],
      adjustments: [
        {
          kind: "coupon",
          sign: "discount",
          amount: 500,
          source: "ai",
          source_text: "Gift Card 500円",
          source_line_index: 0
        }
      ],
      payments: [
        { method: "Gift Card", amount: 500, source_text: "Gift Card 500円", source_line_index: 0 }
      ]
    )

    aggregate_failures do
      expect(without_payment.adjustments).to eq([])
      expect(without_payment.payments).to contain_exactly(include(method: "Gift Card", amount: 500))
      expect(with_payment.adjustments).to eq([])
      expect(with_payment.payments).to contain_exactly(include(method: "Gift Card", amount: 500))
    end
  end

  it "tax detail sourceをadjustmentとして重複保存しない" do
    result = resolve(
      lines: [ "10%対象 91円 税額 9円" ],
      adjustments: [
        {
          kind: "coupon",
          sign: "discount",
          amount: 9,
          source: "ai",
          source_text: "10%対象 91円 税額 9円",
          source_line_index: 0
        }
      ],
      tax_details: [ { description: "税額", rate: 0.1, net_amount: 91, amount: 9 } ]
    )

    aggregate_failures do
      expect(result.adjustments).to eq([])
      expect(result.tax_details).to contain_exactly(include(amount: 9, net_amount: 91))
    end
  end

  it "同じsource spanの同一adjustmentだけを重複排除する" do
    line = "クーポン -100円"
    token = Analysis::SourceEvidenceIndex.call(lines: [ line ], money_pattern: money_pattern, profile: profile).first[:tokens].first
    adjustment = {
      kind: "coupon",
      sign: "discount",
      amount: 100,
      source: "ocr",
      source_text: line,
      source_line_index: 0,
      source_span_start: token[:span_start],
      source_span_end: token[:span_end]
    }

    result = resolve(lines: [ line ], adjustments: [ adjustment, adjustment.dup ])

    expect(result.adjustments).to contain_exactly(include(kind: "coupon", amount: 100))
  end

  it "同じ行・同額でも異なるsource spanなら別adjustmentとして残す" do
    line = "クーポン -100円 クーポン -100円"
    tokens = Analysis::SourceEvidenceIndex.call(lines: [ line ], money_pattern: money_pattern, profile: profile).first[:tokens]
    adjustments = tokens.map do |token|
      {
        kind: "coupon",
        sign: "discount",
        amount: 100,
        source: "ocr",
        source_text: line,
        source_line_index: 0,
        source_span_start: token[:span_start],
        source_span_end: token[:span_end]
      }
    end

    result = resolve(lines: [ line ], adjustments: adjustments)

    expect(result.adjustments.size).to eq(2)
  end

  it "provenanceがない同額・同labelのadjustmentを重複と断定しない" do
    adjustment = {
      kind: "coupon",
      sign: "discount",
      amount: 100,
      source: "ocr",
      label: "クーポン"
    }

    result = resolve(lines: [], adjustments: [ adjustment, adjustment.dup ])

    expect(result.adjustments.size).to eq(2)
  end
end
