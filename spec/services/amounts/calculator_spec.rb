require 'rails_helper'

RSpec.describe Amounts::Calculator do
  def calculate(receipt: {}, items: [], tax_details: [], context: :analysis, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil, item_basis: nil, item_basis_assignments: nil, tax_basis: nil)
    kwargs = {
      receipt: receipt,
      items: items,
      tax_details: tax_details,
      context: context
    }
    kwargs[:rounding_mode] = rounding_mode if rounding_mode
    kwargs[:tax_rounding_mode] = tax_rounding_mode if tax_rounding_mode
    kwargs[:discount_rounding_mode] = discount_rounding_mode if discount_rounding_mode
    kwargs[:item_basis] = item_basis if item_basis
    kwargs[:item_basis_assignments] = item_basis_assignments if item_basis_assignments
    kwargs[:tax_basis] = tax_basis if tax_basis

    described_class.new(**kwargs).call
  end

  describe '#call' do
    it 'defaults rounding_mode to floor' do
      result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result[:total]).to eq(108)
        expect(result[:subtotal]).to eq(99)
        expect(result[:tax]).to eq(9)
      end
    end

    it 'supports floor, ceil, and round when tax differs by rounding mode' do
      floor_result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        rounding_mode: :floor
      )
      ceil_result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        rounding_mode: :ceil
      )
      round_result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        rounding_mode: :round
      )

      aggregate_failures do
        expect(floor_result[:tax]).to eq(9)
        expect(ceil_result[:tax]).to eq(10)
        expect(round_result[:tax]).to eq(10)
      end
    end

    it 'reverse-calculates subtotal and tax from tax-included total' do
      result = calculate(
        items: [
          { line_total: 999, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result[:total]).to eq(999)
        expect(result[:subtotal]).to eq(909)
        expect(result[:tax]).to eq(90)
      end
    end

    it 'corrects total from subtotal plus tax when item data is absent' do
      result = calculate(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        }
      )

      expect(result[:total]).to eq(1_100)
    end

    it 'corrects tax from total minus subtotal when item data is absent' do
      result = calculate(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000
        }
      )

      expect(result[:tax]).to eq(100)
    end

    it 'fills tax from subtotal and tax_rate using tax rounding when item data is absent' do
      result = calculate(
        receipt: {
          subtotal_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        tax_rounding_mode: :floor
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(999)
        expect(result[:tax]).to eq(99)
        expect(result[:total]).to eq(1_098)
      end
    end

    it 'infers tax_rate from tax_amount divided by subtotal_amount' do
      result = calculate(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        }
      )

      expect(result[:tax_rate]).to eq(BigDecimal('0.1'))
    end

    it 'sets tax_rate to nil when multiple item tax rates exist' do
      result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ]
      )

      expect(result[:tax_rate]).to be_nil
    end

    it 'prefers multiple tax_details in analysis context and keeps tax_rate nil' do
      result = calculate(
        items: [
          { line_total: 1_090 }
        ],
        tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 500, amount: 40 },
          { rate: BigDecimal('0.1'), net_amount: 500, amount: 50 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(1_000)
        expect(result[:tax]).to eq(90)
        expect(result[:total]).to eq(1_090)
        expect(result[:tax_rate]).to be_nil
      end
    end

    it 'does not use partial tax_details as the resolved total source when item_total is larger' do
      result = calculate(
        items: [
          { line_total: 130, tax_rate: BigDecimal('0.08') },
          { line_total: 140, tax_rate: BigDecimal('0.08') },
          { line_total: 300, tax_rate: BigDecimal('0.1') },
          { line_total: 490, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21 },
          { rate: BigDecimal('0.1'), net_amount: 300, amount: 30 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:tax_details_primary]).to be(false)
        expect(result[:total]).to eq(1_110)
        expect(result[:total]).not_to eq(621)
        expect(result[:tax_rate]).to be_nil
      end
    end

    it 'uses tax_details when item tax_rate is missing in analysis context' do
      result = calculate(
        items: [
          { line_total: 1_100 }
        ],
        tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(1_000)
        expect(result[:tax]).to eq(100)
        expect(result[:total]).to eq(1_100)
        expect(result[:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end

    it 'does not treat ordinary tax-included tax_details as external tax' do
      result = calculate(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        items: [
          { line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:external_tax]).to be(false)
        expect(result[:subtotal]).to eq(455)
        expect(result[:tax]).to eq(45)
        expect(result[:total]).to eq(500)
      end
    end

    it 'treats explicit external tax_details as external tax' do
      result = calculate(
        receipt: {
          total_amount: 500
        },
        items: [
          { line_total: 455, tax_rate: BigDecimal('0.1') }
        ],
        tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45, description: '外税 10%' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:external_tax]).to be(true)
        expect(result[:subtotal]).to eq(455)
        expect(result[:tax]).to eq(45)
        expect(result[:total]).to eq(500)
      end
    end

    it 'calculates tax excluded item basis from item line totals' do
      result = calculate(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100
        },
        items: [
          { line_total: 1_000, tax_rate: BigDecimal('0.1') }
        ],
        tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100, description: '外税 10%' }
        ],
        item_basis: :tax_excluded,
        tax_basis: :external
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(1_000)
        expect(result[:tax]).to eq(100)
        expect(result[:total]).to eq(1_100)
        expect(result[:tax_basis]).to eq(:external)
        expect(result[:item_basis]).to eq(:tax_excluded)
      end
    end

    it 'calculates mixed item basis from supplied tax rate group assignments' do
      result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 200, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        item_basis: :mixed,
        item_basis_assignments: [
          { tax_rate: BigDecimal('0.08'), basis: :tax_included, net_amount: 100, tax_amount: 8, gross_amount: 108 },
          { tax_rate: BigDecimal('0.1'), basis: :tax_excluded, net_amount: 200, tax_amount: 20, gross_amount: 220 },
          { tax_rate: BigDecimal('0'), basis: :non_taxable, net_amount: 50, tax_amount: 0, gross_amount: 50 }
        ]
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(350)
        expect(result[:tax]).to eq(28)
        expect(result[:total]).to eq(378)
        expect(result[:item_basis]).to eq(:mixed)
        expect(result[:tax_details]).to include(
          hash_including(rate: BigDecimal('0.08'), net_amount: 100, amount: 8),
          hash_including(rate: BigDecimal('0.1'), net_amount: 200, amount: 20)
        )
      end
    end

    it 'prefers item calculation over conflicting tax_details in edit_save context when items exist' do
      result = calculate(
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(99)
        expect(result[:tax]).to eq(9)
        expect(result[:total]).to eq(108)
      end
    end

    it 'uses tax_details in manual context when no items exist' do
      result = calculate(
        tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:subtotal]).to eq(1_000)
        expect(result[:tax]).to eq(100)
        expect(result[:total]).to eq(1_100)
        expect(result[:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end
  end
end
