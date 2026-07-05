require 'rails_helper'

RSpec.describe Amounts::EvidenceExtractor do
  describe '.payment_evidence' do
    let(:payment) do
      {
        evidence: [
          {
            source: "receipt_payments",
            payment_amount_sum: 1_000,
            final_payment_total: 800,
            payment_delta: 200
          }
        ]
      }
    end

    it '支払過払いsuppress時に既存evidenceへmarkerを付与する' do
      expect(described_class.payment_evidence(payment, suppress_positive_overpayment: true)).to eq(
        [
          {
            source: "receipt_payments",
            payment_amount_sum: 1_000,
            final_payment_total: 800,
            payment_delta: 200,
            payment_amount_mismatch_suppressed: true,
            suppressed_reason: "tendered_like_overpayment"
          }
        ]
      )
    end

    it 'suppress対象外ではpayment evidenceを変更しない' do
      expect(described_class.payment_evidence(payment, suppress_positive_overpayment: false)).to eq(payment[:evidence])
    end
  end

  describe '.adjustment_evidence' do
    it '分類済みadjustmentのevidenceだけを返す' do
      classified_adjustments = [
        {
          classification: {
            evidence: {
              source: "receipt_adjustment",
              kind: "coupon",
              amount: 100
            }
          }
        }
      ]

      expect(described_class.adjustment_evidence(classified_adjustments)).to eq(
        [
          {
            source: "receipt_adjustment",
            kind: "coupon",
            amount: 100
          }
        ]
      )
    end
  end

  describe '.incomplete_tax_detail_evidence' do
    it '税額のみのtax detail evidenceを既存shapeで返す' do
      expect(
        described_class.incomplete_tax_detail_evidence(
          [
            {
              description: "10%対象税額",
              amount: 95
            }
          ]
        )
      ).to eq(
        [
          {
            source: "receipt_tax_detail",
            index: 0,
            basis: :tax_only,
            description: "10%対象税額",
            amount: 95
          }
        ]
      )
    end
  end
end
