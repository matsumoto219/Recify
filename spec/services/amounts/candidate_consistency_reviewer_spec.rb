require 'rails_helper'

RSpec.describe Amounts::CandidateConsistencyReviewer do
  def review(items:, candidate:, context: :edit_save, receipt: {}, tax_details: [])
    described_class.new(
      receipt: receipt,
      items: items,
      tax_details: tax_details,
      context: context
    ).call(candidate)
  end

  def candidate_for(
    purchase_total:,
    computed_items:,
    basis: 'items_as_tax_included',
    subtotal: purchase_total,
    tax: 0,
    rounding_mode: :round,
    rounding_scope: :per_item,
    tax_rate_groups: [],
    calculation_profile: { item_amount_basis: :line_total_as_recorded }
  )
    Amounts::Candidate.new(
      candidate_id: 'candidate',
      basis: basis,
      subtotal: subtotal,
      tax: tax,
      purchase_total: purchase_total,
      final_payment_total: purchase_total,
      purchase_adjustment_total: 0,
      payment_adjustment_total: 0,
      tax_details: [],
      tax_rate_groups: tax_rate_groups,
      rounding_mode: rounding_mode,
      rounding_scope: rounding_scope,
      warnings: [],
      computed_items: computed_items,
      calculation_profile: calculation_profile,
      source: :amount_engine
    )
  end

  def reference_item(**overrides)
    {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: '120',
      reference_quantity: '500',
      reference_quantity_unit_code: 'milliliter',
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: 'gross',
      quantity: '1.5',
      quantity_unit_code: 'liter',
      quantity_unit_raw: nil,
      price: nil,
      original_line_total: 360,
      line_total: 360,
      discount_amount: nil,
      discount_rate: nil,
      needs_review: false,
      tax_rate: nil
    }.merge(overrides)
  end

  def explicit_diagnostic_item(line_total:, **overrides)
    reference_item(
      pricing_source_kind: 'explicit_line_total',
      reference_price_amount: '100',
      reference_quantity: '3',
      reference_quantity_unit_code: 'each',
      reference_price_tax_inclusion: 'gross',
      quantity: '1',
      quantity_unit_code: 'each',
      original_line_total: line_total,
      line_total: line_total,
      **overrides
    )
  end

  describe 'source authority aware item review' do
    it 'complete reference formulaの0円をitem dataとして扱う' do
      item = reference_item(
        reference_price_amount: '0',
        reference_quantity: '1',
        reference_quantity_unit_code: 'each',
        quantity: '2',
        quantity_unit_code: 'each',
        original_line_total: 0,
        line_total: 0,
        amount_line_total_present: false
      )
      candidate = candidate_for(purchase_total: 0, computed_items: [ item ])

      reviewed = review(items: [ item ], candidate: candidate)

      expect(reviewed.warnings).not_to include(:insufficient_data)
    end

    it 'reference authorityのstale price・hidden totalをlegacy unit total比較に使わない' do
      item = reference_item(
        reference_price_amount: '50',
        reference_quantity: '1',
        reference_quantity_unit_code: 'each',
        quantity: '3',
        quantity_unit_code: 'each',
        price: 999,
        original_line_total: 998,
        line_total: 997
      )
      candidate = candidate_for(purchase_total: 997, computed_items: [ item ])

      reviewed = review(items: [ item ], candidate: candidate)

      expect(reviewed.warnings).not_to include(:item_total_mismatch)
    end

    it 'explicit authorityをcountable unitでもlegacy price x quantity比較に使わない' do
      item = {
        pricing_source_kind: 'explicit_line_total',
        price: 999,
        quantity: 3,
        quantity_unit_code: 'each',
        original_line_total: 150,
        line_total: 150
      }
      candidate = candidate_for(purchase_total: 150, computed_items: [ item ])

      reviewed = review(items: [ item ], candidate: candidate)

      expect(reviewed.warnings).not_to include(:item_total_mismatch)
    end

    it 'legacyとcount formulaのcountable unit不一致検知は維持する' do
      items = [
        {
          pricing_source_kind: nil,
          price: 999,
          quantity: 3,
          quantity_unit_code: 'each',
          original_line_total: 150,
          line_total: 150
        },
        {
          pricing_source_kind: 'count_unit_price',
          price: 999,
          quantity: 3,
          quantity_unit_code: 'each',
          original_line_total: 150,
          line_total: 150
        }
      ]

      aggregate_failures do
        items.each do |item|
          candidate = candidate_for(purchase_total: 150, computed_items: [ item ])
          reviewed = review(items: [ item ], candidate: candidate)

          expect(reviewed.warnings).to include(:item_total_mismatch), item.inspect
        end
      end
    end
  end

  describe 'explicit total with reference diagnostic evidence' do
    it 'candidateのgross basisと一致するformulaのfloor・half-up・ceil候補を許容する' do
      exact_amount = Rational(100, 3)
      permitted_totals = [
        exact_amount.floor,
        (BigDecimal(exact_amount.numerator.to_s) / exact_amount.denominator).round(0, :half_up).to_i,
        exact_amount.ceil
      ]

      aggregate_failures do
        permitted_totals.each do |line_total|
          item = explicit_diagnostic_item(line_total: line_total)
          candidate = candidate_for(purchase_total: line_total, computed_items: [ item ])
          reviewed = review(items: [ item ], candidate: candidate)

          expect(reviewed.warnings).not_to include(:item_total_mismatch), "line_total=#{line_total}"
        end
      end
    end

    it 'same item・gross basisが確実でrounding候補のどれにも一致しない時だけmismatchにする' do
      item = explicit_diagnostic_item(line_total: 35)
      candidate = candidate_for(purchase_total: 35, computed_items: [ item ])

      reviewed = review(items: [ item ], candidate: candidate)

      aggregate_failures do
        expect(reviewed.warnings).to include(:item_total_mismatch)
        expect(reviewed.purchase_total).to eq(35)
        expect(reviewed.computed_items.first[:line_total]).to eq(35)
      end
    end

    it 'generic review flagと無関係にsame-basisの完全なformulaは比較する' do
      item = explicit_diagnostic_item(line_total: 35, needs_review: true)
      candidate = candidate_for(purchase_total: 35, computed_items: [ item ])

      reviewed = review(items: [ item ], candidate: candidate)

      expect(reviewed.warnings).to include(:item_total_mismatch)
    end

    it 'basis不一致・raw・不完全・basis不明はformulaと比較しない' do
      cases = [
        explicit_diagnostic_item(
          line_total: 35,
          reference_price_tax_inclusion: 'net',
          tax_rate: BigDecimal('0.1')
        ),
        explicit_diagnostic_item(
          line_total: 35,
          reference_quantity_unit_code: nil,
          reference_quantity_unit_raw: 'fluid_ounce'
        ),
        explicit_diagnostic_item(line_total: 35, reference_quantity: nil),
        explicit_diagnostic_item(line_total: 35, reference_price_tax_inclusion: nil)
      ]

      aggregate_failures do
        cases.each do |item|
          candidate = candidate_for(purchase_total: 35, computed_items: [ item ])
          reviewed = review(items: [ item ], candidate: candidate)

          expect(reviewed.warnings).not_to include(:item_total_mismatch), item.inspect
        end
      end
    end

    it 'net diagnosticは税率欠損・不正時もprinted totalのgross basisを推測せず比較しない' do
      [ nil, 'invalid' ].each do |tax_rate|
        item = explicit_diagnostic_item(
          line_total: 35,
          reference_price_tax_inclusion: 'net',
          tax_rate: tax_rate
        )
        candidate = candidate_for(purchase_total: 35, computed_items: [ item ])

        reviewed = review(items: [ item ], candidate: candidate)

        expect(reviewed.warnings).not_to include(:item_total_mismatch), tax_rate.inspect
      end
    end

    it '明示0%ではgross/netが同値なのでnet diagnosticも比較できる' do
      item = explicit_diagnostic_item(
        line_total: 35,
        reference_price_tax_inclusion: 'net',
        tax_rate: BigDecimal('0')
      )
      candidate = candidate_for(purchase_total: 35, computed_items: [ item ])

      reviewed = review(items: [ item ], candidate: candidate)

      expect(reviewed.warnings).to include(:item_total_mismatch)
    end

    it 'malformed diagnostic evidenceはraiseせずprinted authorityを維持し比較不能とする' do
      cases = [
        explicit_diagnostic_item(line_total: 35, quantity_unit_code: 'gram'),
        explicit_diagnostic_item(line_total: 35, reference_quantity_unit_code: 'g'),
        explicit_diagnostic_item(line_total: 35, reference_quantity_unit_code: 'unknown'),
        explicit_diagnostic_item(line_total: 35, reference_quantity: '0'),
        explicit_diagnostic_item(line_total: 35, reference_quantity: Float::NAN),
        explicit_diagnostic_item(line_total: 35, reference_quantity: '1.0001'),
        explicit_diagnostic_item(line_total: 35, reference_quantity: '10000'),
        explicit_diagnostic_item(line_total: 35, reference_price_amount: '1.1234567'),
        explicit_diagnostic_item(line_total: 35, reference_price_amount: '1000000000000'),
        explicit_diagnostic_item(line_total: 35, quantity: Float::NAN),
        explicit_diagnostic_item(line_total: 35, quantity: '1.0001'),
        explicit_diagnostic_item(line_total: 35, quantity: '10000')
      ]

      aggregate_failures do
        cases.each do |item|
          candidate = candidate_for(purchase_total: 35, computed_items: [ item ])

          expect { review(items: [ item ], candidate: candidate) }.not_to raise_error
          reviewed = review(items: [ item ], candidate: candidate)
          expect(reviewed.warnings).not_to include(:item_total_mismatch), item.inspect
          expect(reviewed.computed_items.first[:line_total]).to eq(35), item.inspect
        end
      end
    end

    it '明示discount evidenceが整合する場合は割引前totalをformulaと比較し割引後totalを維持する' do
      matching = explicit_diagnostic_item(
        line_total: 30,
        original_line_total: 34,
        discount_amount: 4,
        discount_rate: BigDecimal('0.117647')
      )
      mismatching = explicit_diagnostic_item(
        line_total: 30,
        original_line_total: 35,
        discount_amount: 5,
        discount_rate: BigDecimal('0.142857')
      )

      aggregate_failures do
        [ [ matching, false ], [ mismatching, true ] ].each do |item, mismatch|
          candidate = candidate_for(purchase_total: 30, computed_items: [ item ])
          reviewed = review(items: [ item ], candidate: candidate)

          expect(reviewed.warnings.include?(:item_total_mismatch)).to eq(mismatch), item.inspect
          expect(reviewed.purchase_total).to eq(30), item.inspect
          expect(reviewed.computed_items.first).to include(
            original_line_total: item[:original_line_total],
            discount_amount: item[:discount_amount],
            line_total: 30
          ), item.inspect
        end
      end
    end

    it '割引前total欠損またはdiscount関係不整合ならformula比較をスキップする' do
      cases = [
        explicit_diagnostic_item(
          line_total: 30,
          original_line_total: nil,
          discount_amount: 4,
          discount_rate: BigDecimal('0.117647')
        ),
        explicit_diagnostic_item(
          line_total: 30,
          original_line_total: 34,
          discount_amount: 5,
          discount_rate: BigDecimal('0.117647')
        ),
        explicit_diagnostic_item(
          line_total: 30,
          original_line_total: 34,
          discount_amount: nil,
          discount_rate: BigDecimal('0.117647')
        )
      ]

      aggregate_failures do
        cases.each do |item|
          candidate = candidate_for(purchase_total: 30, computed_items: [ item ])
          reviewed = review(items: [ item ], candidate: candidate)

          expect(reviewed.warnings).not_to include(:item_total_mismatch), item.inspect
          expect(reviewed.computed_items.first[:line_total]).to eq(30), item.inspect
        end
      end
    end
  end

  describe 'reference net group rounding' do
    it 'small amount 2行のper-tax-rate-group丸めによる1円差をitem mismatchにしない' do
      items = 2.times.map do
        reference_item(
          reference_price_amount: '5',
          reference_quantity: '1',
          reference_quantity_unit_code: 'each',
          reference_price_tax_inclusion: 'net',
          quantity: '1',
          quantity_unit_code: 'each',
          original_line_total: 5,
          line_total: 5,
          tax_rate: BigDecimal('0.1')
        )
      end
      candidate = candidate_for(
        purchase_total: 11,
        subtotal: 10,
        tax: 1,
        computed_items: items.map { |item| item.merge(line_total: 6) },
        rounding_scope: :per_tax_rate_group,
        rounding_mode: :round,
        tax_rate_groups: [ { rate: BigDecimal('0.1'), gross: 11, net: 10, tax: 1 } ],
        calculation_profile: { item_amount_basis: :line_total_as_net }
      )

      reviewed = review(items: items, candidate: candidate)

      expect(reviewed.warnings).not_to include(:item_total_mismatch)
    end

    it 'reference netのgroup丸めとlegacy gross行をgeneric item sumで誤比較しない' do
      reference_items = 2.times.map do
        reference_item(
          reference_price_amount: '5',
          reference_quantity: '1',
          reference_quantity_unit_code: 'each',
          reference_price_tax_inclusion: 'net',
          quantity: '1',
          quantity_unit_code: 'each',
          original_line_total: 5,
          line_total: 5,
          tax_rate: BigDecimal('0.1')
        )
      end
      legacy_gross = {
        pricing_source_kind: nil,
        price: nil,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 110,
        tax_rate: BigDecimal('0.1')
      }
      items = reference_items + [ legacy_gross ]
      computed_items = reference_items.map { |item| item.merge(line_total: 6) } + [ legacy_gross ]
      candidate = candidate_for(
        purchase_total: 121,
        subtotal: 110,
        tax: 11,
        computed_items: computed_items,
        rounding_scope: :per_tax_rate_group,
        rounding_mode: :round,
        tax_rate_groups: [ { rate: BigDecimal('0.1'), gross: 121, net: 110, tax: 11 } ],
        calculation_profile: { item_amount_basis: :mixed_by_tax_rate_group }
      )

      reviewed = review(items: items, candidate: candidate)

      expect(reviewed.warnings).not_to include(:item_total_mismatch)
    end

    it 'reference gross/net混在のitem-derived candidateをgeneric item sumで誤比較しない' do
      gross = reference_item(
        reference_price_amount: '110',
        reference_quantity: '1',
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross',
        quantity: '1',
        quantity_unit_code: 'each',
        original_line_total: 110,
        line_total: 110,
        tax_rate: BigDecimal('0.1')
      )
      net = reference_item(
        reference_price_amount: '100',
        reference_quantity: '1',
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'net',
        quantity: '1',
        quantity_unit_code: 'each',
        original_line_total: 100,
        line_total: 100,
        tax_rate: BigDecimal('0.1')
      )
      candidate = candidate_for(
        purchase_total: 220,
        subtotal: 200,
        tax: 20,
        computed_items: [ gross, net.merge(line_total: 110) ],
        rounding_scope: :per_tax_rate_group,
        rounding_mode: :round,
        tax_rate_groups: [ { rate: BigDecimal('0.1'), gross: 220, net: 200, tax: 20 } ],
        calculation_profile: { item_amount_basis: :mixed_by_tax_rate_group }
      )

      reviewed = review(items: [ gross, net ], candidate: candidate)

      expect(reviewed.warnings).not_to include(:item_total_mismatch)
    end

    it 'discount後のreference netとtax projectionの差をgeneric item sumで誤比較しない' do
      item = reference_item(
        reference_price_amount: '100',
        reference_quantity: '1',
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'net',
        quantity: '1',
        quantity_unit_code: 'each',
        original_line_total: 100,
        discount_amount: 10,
        discount_rate: BigDecimal('0.1'),
        line_total: 90,
        tax_rate: BigDecimal('0.1')
      )
      candidate = candidate_for(
        purchase_total: 99,
        subtotal: 90,
        tax: 9,
        computed_items: [ item.merge(line_total: 99) ],
        calculation_profile: { item_amount_basis: :line_total_as_net }
      )

      reviewed = review(items: [ item ], candidate: candidate)

      expect(reviewed.warnings).not_to include(:item_total_mismatch)
    end
  end
end
