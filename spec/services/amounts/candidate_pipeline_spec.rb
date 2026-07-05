require 'rails_helper'

RSpec.describe Amounts::CandidatePipeline do
  it 'candidate生成と評価を一つの入口で実行する' do
    candidates = described_class.new(
      receipt: { total_amount: 1_100, subtotal_amount: 1_000, tax_amount: 100 },
      items: [
        { name: 'item', line_total: 1_100, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [],
      adjustments: [],
      payments: [
        { method: 'cash', amount: 1_100 }
      ],
      context: :analysis,
      tax_rounding_modes: [ :floor ],
      discount_rounding_modes: [ :floor ],
      scoring_discount_rounding_mode: :floor,
      tax_excluded_price_conversion_enabled: true
    ).call

    aggregate_failures do
      expect(candidates).to all(be_a(Amounts::Candidate))
      expect(candidates).to all(have_attributes(score_breakdown: include(:receipt_total_delta)))
    end
  end
end
