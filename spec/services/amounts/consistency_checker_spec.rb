require 'rails_helper'

RSpec.describe Amounts::ConsistencyChecker do
  def check(computed:, resolved:, item_total:, tax_total:, receipt: {}, context: :analysis, items: [], item_count: nil, external_tax: false, source_tax_details: [], generated_tax_details: [], rounding_mode: :floor)
    described_class.new(
      computed: computed,
      resolved: resolved,
      item_total: item_total,
      tax_total: tax_total,
      receipt: receipt,
      context: context,
      items: items,
      item_count: item_count || items.size,
      external_tax: external_tax,
      source_tax_details: source_tax_details,
      generated_tax_details: generated_tax_details,
      rounding_mode: rounding_mode
    ).call
  end

  describe '#call' do
    it 'does not mark mismatch when floor differs but ceil or round matches tax_details' do
      inconsistencies = check(
        computed: {
          item_tax_total: 9,
          tax_detail_total: 10
        },
        resolved: {
          subtotal: 99,
          tax: 9,
          total: 108,
          tax_rate: BigDecimal('0.1')
        },
        item_total: 108,
        tax_total: 9,
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        source_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 98, amount: 10 }
        ],
        generated_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: 9 }
        ]
      )

      aggregate_failures do
        expect(inconsistencies).not_to include(:tax_amount_mismatch)
        expect(inconsistencies).not_to include(:tax_detail_mismatch)
        expect(inconsistencies).not_to include(:tax_detail_rate_mismatch)
      end
    end

    it 'marks mismatch when item calculation and tax_details clearly conflict outside rounding candidates' do
      inconsistencies = check(
        computed: {
          item_tax_total: 9,
          tax_detail_total: 30
        },
        resolved: {
          subtotal: 99,
          tax: 9,
          total: 108,
          tax_rate: BigDecimal('0.1')
        },
        item_total: 108,
        tax_total: 9,
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        source_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 78, amount: 30 }
        ],
        generated_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: 9 }
        ]
      )

      expect(inconsistencies).to include(:tax_detail_mismatch)
    end

    it 'marks incomplete tax_details as warning candidate without tax_detail_mismatch when net_amount is missing' do
      inconsistencies = check(
        computed: {
          item_tax_total: 9,
          tax_detail_total: 9
        },
        resolved: {
          subtotal: 99,
          tax: 9,
          total: 108,
          tax_rate: BigDecimal('0.1')
        },
        item_total: 108,
        tax_total: 9,
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        source_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: nil, amount: 9 }
        ],
        generated_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: 9 }
        ]
      )

      aggregate_failures do
        expect(inconsistencies).to include(:tax_detail_incomplete)
        expect(inconsistencies).not_to include(:tax_detail_mismatch)
      end
    end

    it 'marks partial tax_details as warning candidate without tax_detail_mismatch' do
      inconsistencies = check(
        computed: {
          item_tax_total: 18,
          tax_detail_total: 8
        },
        resolved: {
          subtotal: 200,
          tax: 18,
          total: 218,
          tax_rate: nil
        },
        item_total: 218,
        tax_total: 18,
        receipt: {
          total_amount: 218,
          subtotal_amount: 200,
          tax_amount: 18
        },
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ],
        source_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 }
        ],
        generated_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 },
          { rate: BigDecimal('0.1'), net_amount: 100, amount: 10 }
        ]
      )

      aggregate_failures do
        expect(inconsistencies).to include(:tax_detail_partial)
        expect(inconsistencies).not_to include(:tax_detail_mismatch)
      end
    end

    it 'does not mark mismatch when item calculation and tax_details match exactly' do
      inconsistencies = check(
        computed: {
          item_tax_total: 9,
          tax_detail_total: 9
        },
        resolved: {
          subtotal: 99,
          tax: 9,
          total: 108,
          tax_rate: BigDecimal('0.1')
        },
        item_total: 108,
        tax_total: 9,
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        source_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: 9 }
        ],
        generated_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: 9 }
        ]
      )

      aggregate_failures do
        expect(inconsistencies).not_to include(:tax_detail_mismatch)
        expect(inconsistencies).not_to include(:tax_detail_rate_mismatch)
      end
    end

    it 'accepts rounding_mode without changing rounding candidate checks' do
      inconsistencies = check(
        computed: {
          item_tax_total: 9,
          tax_detail_total: 10
        },
        resolved: {
          subtotal: 99,
          tax: 9,
          total: 108,
          tax_rate: BigDecimal('0.1')
        },
        item_total: 108,
        tax_total: 9,
        items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        source_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 98, amount: 10 }
        ],
        generated_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: 9 }
        ],
        rounding_mode: :ceil
      )

      expect(inconsistencies).not_to include(:tax_detail_mismatch)
    end
  end
end
