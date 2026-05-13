require 'rails_helper'

RSpec.describe Amounts::Calculator do
  def calculate(receipt: {}, items: [], tax_details: [], rounding_mode: nil)
    kwargs = {
      receipt: receipt,
      items: items,
      tax_details: tax_details
    }
    kwargs[:rounding_mode] = rounding_mode if rounding_mode

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
  end
end
