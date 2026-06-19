require 'rails_helper'

RSpec.describe Amounts::CandidateGenerator do
  def generate(receipt: {}, items: [], tax_details: [], adjustments: [], payments: [], context: :analysis, tax_rounding_modes: [ :floor ], discount_rounding_modes: [ :round ])
    described_class.new(
      receipt: receipt,
      items: items,
      tax_details: tax_details,
      adjustments: adjustments,
      payments: payments,
      context: context,
      tax_rounding_modes: tax_rounding_modes,
      discount_rounding_modes: discount_rounding_modes
    ).call
  end

  it 'generates candidates for each discount rounding mode' do
    candidates = generate(
      items: [
        {
          price: 271,
          quantity: 1,
          quantity_unit_code: 'each',
          line_total: nil,
          discount_rate: BigDecimal('0.5'),
          tax_rate: BigDecimal('0')
        }
      ],
      discount_rounding_modes: %i[floor round ceil]
    )

    included = candidates.select do |candidate|
      candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
    end
    by_discount_rounding = included.index_by { |candidate| candidate.calculation_profile[:discount_rounding_mode] }

    aggregate_failures do
      # 検算: 271円の50%引き。floorは割引135円で残額136円、round/ceilは割引136円で残額135円。
      expect(by_discount_rounding.keys).to contain_exactly(:floor, :round, :ceil)
      expect(by_discount_rounding[:floor].purchase_total).to eq(136)
      expect(by_discount_rounding[:floor].computed_items.first[:discount_amount]).to eq(135)
      expect(by_discount_rounding[:round].purchase_total).to eq(135)
      expect(by_discount_rounding[:round].computed_items.first[:discount_amount]).to eq(136)
      expect(by_discount_rounding[:ceil].purchase_total).to eq(135)
      expect(by_discount_rounding[:ceil].computed_items.first[:discount_amount]).to eq(136)
    end
  end
end
