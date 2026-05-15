require 'rails_helper'

RSpec.describe Amounts::CalculationProfileEstimator do
  def estimate(receipt:, items:, tax_details:, tax_rounding_modes: nil, discount_rounding_modes: nil)
    described_class.new(
      receipt: receipt,
      items: items,
      tax_details: tax_details,
      tax_rounding_modes: tax_rounding_modes,
      discount_rounding_modes: discount_rounding_modes
    ).call
  end

  let(:aeon_receipt) do
    {
      total_amount: 4_215,
      subtotal_amount: 3_903,
      tax_amount: 312,
      tax_rate: BigDecimal('0.08')
    }
  end

  let(:aeon_items) do
    [
      {
        price: 271,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 271,
        discount_amount: 136,
        discount_rate: BigDecimal('0.5'),
        line_total: 135,
        tax_rate: BigDecimal('0.08')
      },
      {
        price: 489,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 489,
        discount_amount: 245,
        discount_rate: BigDecimal('0.5'),
        line_total: 244,
        tax_rate: BigDecimal('0.08')
      },
      {
        price: 432,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 432,
        discount_amount: 130,
        discount_rate: BigDecimal('0.3'),
        line_total: 302,
        tax_rate: BigDecimal('0.08')
      },
      {
        price: 3_222,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 3_222,
        discount_amount: 0,
        line_total: 3_222,
        tax_rate: BigDecimal('0.08')
      }
    ]
  end

  let(:aeon_tax_details) do
    [
      {
        rate: BigDecimal('0.08'),
        net_amount: 3_903,
        amount: 312
      }
    ]
  end

  it 'selects floor tax, round discount, external tax basis for Receipt 68 style data' do
    result = estimate(
      receipt: aeon_receipt,
      items: aeon_items,
      tax_details: aeon_tax_details
    )

    aggregate_failures do
      expect(result[:profile]).to eq(
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round,
        tax_basis: :external,
        item_basis: :tax_included
      )
      expect(result[:score]).to eq(0)
      expect(result[:candidates]).to be_present
      expect(result[:warnings]).to eq([])
    end
  end

  it 'evaluates tax excluded item basis candidates when external tax evidence is present' do
    result = estimate(
      receipt: {
        subtotal_amount: 1_000,
        tax_amount: 100,
        total_amount: 1_100
      },
      items: [
        {
          price: 1_000,
          quantity: 1,
          quantity_unit: '個',
          line_total: 1_000,
          tax_rate: BigDecimal('0.1')
        }
      ],
      tax_details: [
        {
          rate: BigDecimal('0.1'),
          net_amount: 1_000,
          amount: 100,
          description: '外税'
        }
      ]
    )

    aggregate_failures do
      expect(result[:profile]).to include(
        tax_basis: :external,
        item_basis: :tax_excluded
      )
      expect(result[:score]).to eq(0)
      expect(result[:candidates].map { |candidate| candidate[:profile][:item_basis] }.uniq).to include(
        :tax_included,
        :tax_excluded,
        :mixed
      )
    end
  end

  it 'returns calculation_profile_uncertain when close candidates use different bases' do
    result = estimate(
      receipt: {
        subtotal_amount: 1_000,
        tax_amount: 100,
        total_amount: 1_101
      },
      items: [
        {
          price: 1_000,
          quantity: 1,
          quantity_unit: '個',
          line_total: 1_000,
          tax_rate: BigDecimal('0.1')
        }
      ],
      tax_details: [
        {
          rate: BigDecimal('0.1'),
          net_amount: 1_000,
          amount: 100,
          description: '外税'
        }
      ]
    )

    expect(result[:warnings]).to include(:calculation_profile_uncertain)
  end

  it 'does not warn when exact zero-score candidates differ only by inference metadata' do
    result = estimate(
      receipt: aeon_receipt,
      items: aeon_items,
      tax_details: aeon_tax_details
    )

    expect(result[:warnings]).to eq([])
  end

  it 'uses tax floor and discount round as tie-breakers' do
    result = estimate(
      receipt: aeon_receipt,
      items: aeon_items,
      tax_details: aeon_tax_details
    )

    zero_score_profiles = result[:candidates]
      .select { |candidate| candidate[:score].zero? }
      .map { |candidate| candidate[:profile] }

    aggregate_failures do
      expect(zero_score_profiles).to include(
        hash_including(tax_rounding_mode: :round, discount_rounding_mode: :ceil)
      )
      expect(result[:profile]).to include(
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round,
        tax_basis: :external
      )
    end
  end

  it 'limits candidates to explicitly supplied rounding modes' do
    result = estimate(
      receipt: aeon_receipt,
      items: aeon_items,
      tax_details: aeon_tax_details,
      tax_rounding_modes: [ :ceil ],
      discount_rounding_modes: [ :floor ]
    )

    aggregate_failures do
      expect(result[:profile]).to include(
        tax_rounding_mode: :ceil,
        discount_rounding_mode: :floor
      )
      expect(result[:candidates].map { |candidate| candidate[:profile][:tax_rounding_mode] }.uniq).to eq([ :ceil ])
      expect(result[:candidates].map { |candidate| candidate[:profile][:discount_rounding_mode] }.uniq).to eq([ :floor ])
    end
  end
end
