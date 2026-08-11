require 'rails_helper'

RSpec.describe Amounts::TaxDetailEvidence do
  let(:tax_details) do
    [
      { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
      { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
      { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' },
      { rate: BigDecimal('0.08'), net_amount: 0, amount: 5, description: '消費税等8%' }
    ]
  end

  it 'final tax detail evidenceだけを候補生成用に返す' do
    evidence = described_class.new(tax_details)

    expect(evidence.final_detected_tax_details.map { |detail| detail[:basis] }).to eq(%i[net gross])
  end

  it '税額のみのdetailをincomplete sourceとして返す' do
    evidence = described_class.new(tax_details)

    expect(evidence.incomplete_source_tax_details).to eq(
      [
        {
          description: '消費税等8%',
          rate: nil,
          net_amount: nil,
          amount: 5
        }
      ]
    )
  end

  it 'mixed basis探索用のtargetを税率ごとに集約する' do
    evidence = described_class.new(tax_details)

    expect(evidence.targets_by_rate).to include(
      BigDecimal('0.08') => {
        rate: BigDecimal('0.08'),
        gross: 291,
        net: 270,
        tax: 21
      },
      BigDecimal('0.10') => {
        rate: BigDecimal('0.10'),
        gross: 820,
        net: 746,
        tax: 74
      }
    )
  end

  it '税額0円の小額税率グループをfinal tax detail evidenceとして保持する' do
    evidence = described_class.new([
      { rate: BigDecimal('0.08'), net_amount: 739, amount: 59, description: '小 計 (税抜8%)' },
      { rate: BigDecimal('0.10'), net_amount: 3, amount: 0, description: '小 計 (税抜10%)' }
    ])

    aggregate_failures do
      expect(evidence.final_detected_tax_details).to contain_exactly(
        include(rate: BigDecimal('0.08'), basis: :net, target_net_amount: 739, target_tax_amount: 59, target_gross_amount: 798),
        include(rate: BigDecimal('0.10'), basis: :net, target_net_amount: 3, target_tax_amount: 0, target_gross_amount: 3)
      )
      expect(evidence.targets_by_rate[BigDecimal('0.10')]).to include(gross: 3, net: 3, tax: 0)
    end
  end

  it '購入金額を確定できる完全な税内訳だけを金額根拠として扱う' do
    complete = described_class.new([
      { rate: BigDecimal('0.10'), net_amount: 100, amount: 10, description: '外税10%' },
      { rate: BigDecimal('0.10'), net_amount: 3, amount: 0, description: '小 計 (税抜10%)' }
    ])
    amount_missing = described_class.new([
      { rate: BigDecimal('0.10'), net_amount: 100, amount: nil, description: '外税10%' }
    ])
    net_missing = described_class.new([
      { rate: BigDecimal('0.10'), net_amount: nil, amount: 10, description: '消費税10%' }
    ])
    missing_zero_tax = described_class.new([
      { rate: BigDecimal('0.10'), net_amount: 3, amount: nil, description: '小 計 (税抜10%)' }
    ])
    mixed_complete_and_incomplete = described_class.new([
      { rate: BigDecimal('0.08'), net_amount: 100, amount: 8, description: '外税8%' },
      { rate: BigDecimal('0.10'), net_amount: nil, amount: 10, description: '消費税10%' }
    ])

    aggregate_failures do
      expect(complete.purchase_amount_evidence_present?).to be(true)
      expect(amount_missing.purchase_amount_evidence_present?).to be(false)
      expect(net_missing.purchase_amount_evidence_present?).to be(false)
      expect(missing_zero_tax.purchase_amount_evidence_present?).to be(false)
      expect(mixed_complete_and_incomplete.purchase_amount_evidence_present?).to be(false)
    end
  end
end
