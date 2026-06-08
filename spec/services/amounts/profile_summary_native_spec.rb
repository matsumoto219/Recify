require 'rails_helper'

RSpec.describe 'Amounts::ProfileSummary native profile regression' do
  def native_summary(receipt:, items:, tax_details: [], adjustments: [], payments: [])
    normalized_items = Amounts::ItemTotalAggregator.new(
      items: items,
      context: :analysis,
      discount_rounding_mode: :round
    ).call[:items]
    candidates = Amounts::CandidateGenerator.new(
      receipt: receipt,
      items: items,
      tax_details: tax_details,
      adjustments: adjustments,
      payments: payments,
      context: :analysis,
      tax_rounding_modes: %i[floor round ceil],
      discount_rounding_modes: %i[floor round ceil]
    ).call
    hard_rejector = Amounts::HardRejector.new(
      receipt: receipt,
      items: normalized_items,
      tax_details: tax_details,
      payments: payments
    )
    reviewer = Amounts::CandidateConsistencyReviewer.new(
      receipt: receipt,
      items: normalized_items,
      tax_details: tax_details,
      context: :analysis
    )
    scorer = Amounts::CandidateScorer.new(
      receipt: receipt,
      payments: payments,
      tax_details: tax_details,
      context: :analysis
    )
    scored = candidates.map { |candidate| scorer.call(reviewer.call(hard_rejector.call(candidate))) }
    selected = Amounts::WinnerSelector.new(scored).call

    Amounts::ProfileSummary.call(
      selected_candidate: selected,
      candidates: scored,
      context: :analysis,
      receipt: receipt,
      items: items,
      tax_details: tax_details
    )
  end

  it 'keeps Receipt 68 style discount/external-tax data on recorded item basis' do
    result = native_summary(
      receipt: {
        total_amount: 4_215,
        subtotal_amount: 3_903,
        tax_amount: 312,
        tax_rate: BigDecimal('0.08')
      },
      items: [
        { price: 271, quantity: 1, quantity_unit: '個', original_line_total: 271, discount_amount: 136, discount_rate: BigDecimal('0.5'), line_total: 135, tax_rate: BigDecimal('0.08') },
        { price: 489, quantity: 1, quantity_unit: '個', original_line_total: 489, discount_amount: 245, discount_rate: BigDecimal('0.5'), line_total: 244, tax_rate: BigDecimal('0.08') },
        { price: 432, quantity: 1, quantity_unit: '個', original_line_total: 432, discount_amount: 130, discount_rate: BigDecimal('0.3'), line_total: 302, tax_rate: BigDecimal('0.08') },
        { price: 3_222, quantity: 1, quantity_unit: '個', original_line_total: 3_222, discount_amount: 0, line_total: 3_222, tax_rate: BigDecimal('0.08') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 3_903, amount: 312 }
      ]
    )

    aggregate_failures do
      expect(result.profile).to eq(
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round,
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_recorded
      )
      expect(result.score).to eq(0)
      expect(result.warnings).to eq([])
    end
  end

  it 'uses tax-excluded item basis when explicit external-tax evidence is present' do
    result = native_summary(
      receipt: { subtotal_amount: 1_000, tax_amount: 100, total_amount: 1_100 },
      items: [
        { price: 1_000, quantity: 1, quantity_unit: '個', line_total: 1_000, tax_rate: BigDecimal('0.1') }
      ],
      tax_details: [
        { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100, description: '外税' }
      ]
    )

    aggregate_failures do
      expect(result.profile).to include(
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_net
      )
      expect(result.score).to eq(0)
      expect(result.warnings).to eq([])
    end
  end

  it 'warns when explicit external-tax totals are close but not exact' do
    result = native_summary(
      receipt: { subtotal_amount: 1_000, tax_amount: 100, total_amount: 1_101 },
      items: [
        { price: 1_000, quantity: 1, quantity_unit: '個', line_total: 1_000, tax_rate: BigDecimal('0.1') }
      ],
      tax_details: [
        { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100, description: '外税' }
      ]
    )

    aggregate_failures do
      # 検算: 外税候補は1,000 + 100 = 1,100。印字total 1,101との差は1円なのでwarning-only。
      expect(result.profile).to include(item_amount_basis: :line_total_as_net)
      expect(result.score).to eq(100)
      expect(result.warnings).to include(:price_tax_inclusion_uncertain)
      expect(result.warnings).not_to include(:calculation_profile_uncertain)
    end
  end

  it 'selects mixed tax-rate group assignments when groups match tax details exactly' do
    result = native_summary(
      receipt: { subtotal_amount: 350, tax_amount: 28, total_amount: 378 },
      items: [
        { line_total: 108, tax_rate: BigDecimal('0.08') },
        { line_total: 200, tax_rate: BigDecimal('0.1') },
        { line_total: 50, tax_rate: nil }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 },
        { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
      ]
    )

    aggregate_failures do
      # 検算: 8%税込108 = net100/tax8、10%税抜200 = gross220、非課税50、合計378。
      expect(result.profile).to include(item_amount_basis: :mixed_by_tax_rate_group)
      expect(result.profile[:item_amount_basis_assignments]).to include(
        hash_including(tax_rate: BigDecimal('0.08'), basis: :tax_included, net_amount: 100, tax_amount: 8, gross_amount: 108),
        hash_including(tax_rate: BigDecimal('0.1'), basis: :tax_excluded, net_amount: 200, tax_amount: 20, gross_amount: 220),
        hash_including(tax_rate: BigDecimal('0'), basis: :non_taxable, net_amount: 50, tax_amount: 0, gross_amount: 50)
      )
      expect(result.score).to eq(0)
      expect(result.warnings).to eq([])
    end
  end

  it 'keeps same-rate mixed as warning-compatible without applying mixed as the main profile' do
    result = native_summary(
      receipt: { subtotal_amount: 200, tax_amount: 20, total_amount: 220 },
      items: [
        { line_total: 110, tax_rate: BigDecimal('0.1') },
        { line_total: 100, tax_rate: BigDecimal('0.1') }
      ],
      tax_details: [
        { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
      ]
    )

    aggregate_failures do
      # 検算: 110税込ならnet100/tax10、100税抜ならgross110。合計は合うが同一税率内混在なのでwarning。
      expect(result.profile[:item_amount_basis]).to eq(:line_total_as_recorded)
      expect(result.profile).not_to include(:item_amount_basis_assignments)
      expect(result.warnings).to eq([ :price_tax_inclusion_uncertain ])
      expect(result.candidates).to include(
        hash_including(
          same_rate_item_amount_basis_assignments: contain_exactly(
            hash_including(assignment_scope: :item, item_indices: [ 0 ], basis: :tax_included),
            hash_including(assignment_scope: :item, item_indices: [ 1 ], basis: :tax_excluded)
          )
        )
      )
    end
  end
end
