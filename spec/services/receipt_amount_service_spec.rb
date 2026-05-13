require 'rails_helper'

RSpec.describe ReceiptAmountService do
  def call_service(receipt:, receipt_items: [], receipt_tax_details: [], context: :analysis, rounding_mode: nil)
    kwargs = {
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      context: context
    }
    kwargs[:rounding_mode] = rounding_mode if rounding_mode

    described_class.call(**kwargs)
  end

  describe '.call' do
    it 'defaults rounding_mode to floor' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
      end
    end

    it 'accepts rounding_mode and applies ceil to representative tax calculation' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        rounding_mode: :ceil
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(98)
        expect(result[:resolved][:tax]).to eq(10)
      end
    end

    it 'corrects total_amount from subtotal_amount plus tax_amount' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        },
        receipt_items: []
      )

      expect(result[:resolved][:total]).to eq(1_100)
    end

    it 'corrects tax_amount from total_amount minus subtotal_amount' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000
        },
        receipt_items: []
      )

      expect(result[:resolved][:tax]).to eq(100)
    end

    it 'infers tax_rate from tax_amount divided by subtotal_amount' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        },
        receipt_items: []
      )

      expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
    end

    it 'sets resolved tax_rate to nil when multiple item tax rates exist' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ]
      )

      expect(result[:resolved][:tax_rate]).to be_nil
    end

    it 'prefers item calculation in manual context when items are present' do
      result = call_service(
        receipt: {
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
      end
    end

    it 'preserves user-entered amounts in manual context when no items exist' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end

    it 'accepts symbol context values' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :manual
      )

      expect(result[:resolved][:total]).to eq(1_100)
    end

    it 'normalizes string context values to symbols' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: 'manual'
      )

      expect(result[:resolved][:total]).to eq(1_100)
    end

    it 'falls back nil context to analysis' do
      result = call_service(
        receipt: {
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: nil
      )

      expect(result[:resolved][:total]).to eq(108)
    end

    it 'preserves user-entered amounts in edit_save context when no items exist' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end

    it 'treats unknown context as analysis' do
      result = call_service(
        receipt: {
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: :unexpected
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
      end
    end

    it 'uses multiple tax_details in analysis context and keeps resolved tax_rate nil' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 1_100 }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 500, amount: 40 },
          { rate: BigDecimal('0.1'), net_amount: 500, amount: 50 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(90)
        expect(result[:resolved][:total]).to eq(1_090)
        expect(result[:resolved][:tax_rate]).to be_nil
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'uses tax_details in analysis context when item tax_rate is missing' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 1_100 }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'prefers item calculation over tax_details in edit_save context when items exist' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
        expect(result[:resolved][:total]).to eq(108)
      end
    end

    it 'uses tax_details in manual context when no items exist' do
      result = call_service(
        receipt: {},
        receipt_items: [],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end
  end
end
