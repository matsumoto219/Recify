require 'rails_helper'

RSpec.describe ReceiptAmountService do
  def call_service(receipt:, receipt_items: [], receipt_tax_details: [], context: :analysis, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    kwargs = {
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      context: context
    }
    kwargs[:rounding_mode] = rounding_mode if rounding_mode
    kwargs[:tax_rounding_mode] = tax_rounding_mode if tax_rounding_mode
    kwargs[:discount_rounding_mode] = discount_rounding_mode if discount_rounding_mode

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
          { line_total: 1_090 }
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

    it 'does not need review for ordinary tax-included tax_details matching item gross total' do
      result = call_service(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 455,
          tax: 45,
          total: 500,
          tax_rate: BigDecimal('0.1')
        )
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review for receipt 59 style line-total-only item with matching tax_details' do
      result = call_service(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { price: nil, quantity: 1, line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 455,
          tax: 45,
          total: 500,
          tax_rate: BigDecimal('0.1')
        )
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not mark item_total_mismatch when price is nil and quantity is 2 but line_total is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: nil, quantity: 2, line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not mark item_total_mismatch when price and quantity are nil but line_total is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: nil, quantity: nil, line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'fills line_total from price multiplied by quantity when line_total is nil' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 250, quantity: 2, quantity_unit: '個', line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:line_total]).to eq(500)
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'keeps discounted line_total derived from original_line_total minus discount_amount' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 300,
            quantity: 2,
            quantity_unit: '個',
            original_line_total: 600,
            discount_amount: 300,
            line_total: 300,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :analysis
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:price]).to eq(300)
        expect(item[:original_line_total]).to eq(600)
        expect(item[:discount_amount]).to eq(300)
        expect(item[:line_total]).to eq(300)
        expect(result[:resolved][:total]).to eq(300)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'converts discount_rate into discount_amount using discount rounding in manual context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 999,
            quantity: 1,
            quantity_unit: '個',
            discount_rate: BigDecimal('0.105'),
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(999)
        expect(item[:discount_amount]).to eq(105)
        expect(item[:line_total]).to eq(894)
        expect(result[:resolved][:total]).to eq(894)
      end
    end

    it 'preserves OCR discount_amount in analysis context even when discount_rate is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 271,
            quantity: 1,
            quantity_unit: '個',
            original_line_total: 271,
            discount_amount: 136,
            discount_rate: BigDecimal('0.5'),
            line_total: 135,
            tax_rate: BigDecimal('0.08')
          }
        ],
        context: :analysis,
        tax_rounding_mode: :floor,
        discount_rounding_mode: :floor
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:discount_amount]).to eq(136)
        expect(item[:line_total]).to eq(135)
      end
    end

    it 'keeps AEON-style OCR discount amounts authoritative in analysis context' do
      result = call_service(
        receipt: {
          total_amount: 4_215,
          subtotal_amount: 3_903,
          tax_amount: 312,
          tax_rate: BigDecimal('0.08')
        },
        receipt_items: [
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
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.08'),
            net_amount: 3_903,
            amount: 312
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].sum { |item| item[:line_total] }).to eq(3_903)
        expect(result[:resolved]).to include(
          subtotal: 3_903,
          tax: 312,
          total: 4_215,
          tax_rate: BigDecimal('0.08')
        )
        expect(result[:inconsistencies]).to eq([])
        expect(result[:needs_review]).to be(false)
        expect(result[:calculation_profile]).to eq(
          tax_rounding_mode: :floor,
          discount_rounding_mode: :round,
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_recorded
        )
        expect(result[:calculation_profile_score]).to eq(0)
        expect(result[:calculation_profile_candidates]).to be_present
      end
    end

    it 'keeps external tax details authoritative in edit_save context when line totals are unchanged' do
      result = call_service(
        receipt: {
          total_amount: 4_215,
          subtotal_amount: 3_903,
          tax_amount: 312,
          tax_rate: BigDecimal('0.08')
        },
        receipt_items: [
          { price: 108, quantity: 2, quantity_unit: '個', line_total: 216, tax_rate: BigDecimal('0.08') },
          { price: 271, quantity: 1, quantity_unit: '個', original_line_total: 271, discount_amount: 136, discount_rate: BigDecimal('0.5'), line_total: 135, tax_rate: BigDecimal('0.08') },
          { price: 3_552, quantity: 1, quantity_unit: '個', line_total: 3_552, tax_rate: BigDecimal('0.08') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 3_903, amount: 312, description: '8%対象' }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 3_903,
          tax: 312,
          total: 4_215,
          tax_rate: BigDecimal('0.08')
        )
        expect(result[:computed]).to include(
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_recorded
        )
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not estimate calculation profile outside analysis context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 999,
            quantity: 1,
            quantity_unit: '個',
            discount_rate: BigDecimal('0.105'),
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to be_nil
        expect(result[:calculation_profile_score]).to be_nil
        expect(result[:calculation_profile_candidates]).to eq([])
      end
    end

    it 'does not estimate calculation profile in edit_save context' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit: '個',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to be_nil
        expect(result[:calculation_profile_score]).to be_nil
        expect(result[:calculation_profile_candidates]).to eq([])
      end
    end

    it 'applies tax excluded calculation profile when strict external tax evidence is complete' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit: '個',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net
        )
        expect(result[:computed]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100,
          item_amount_basis: :line_total_as_net
        )
        expect(result[:resolved]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100
        )
        expect(result[:inconsistencies]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not apply tax excluded calculation profile when candidates are ambiguous' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_101
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit: '個',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :line_total_as_net)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_inconsistencies]).not_to include(:calculation_profile_uncertain)
        expect(result[:computed]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100,
          item_amount_basis: :line_total_as_recorded
        )
        expect(result[:resolved]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100
        )
      end
    end

    it 'does not apply tax excluded calculation profile when printed subtotal tax total are incomplete' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit: '個',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :line_total_as_net)
        expect(result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'applies mixed calculation profile when tax rate group assignments exactly match printed amounts' do
      result = call_service(
        receipt: {
          subtotal_amount: 350,
          tax_amount: 28,
          total_amount: 378
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 200, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 },
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(result[:computed]).to include(
          subtotal: 350,
          tax: 28,
          total: 378,
          item_amount_basis: :mixed_by_tax_rate_group
        )
        expect(result[:resolved]).to include(
          subtotal: 350,
          tax: 28,
          total: 378
        )
        expect(result[:tax_details]).to include(
          hash_including(rate: BigDecimal('0.08'), net_amount: 100, amount: 8),
          hash_including(rate: BigDecimal('0.1'), net_amount: 200, amount: 20)
        )
        expect(result[:inconsistencies]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not apply mixed calculation profile when printed subtotal tax total are incomplete' do
      result = call_service(
        receipt: {
          total_amount: 378
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 200, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 },
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_inconsistencies]).not_to include(:calculation_profile_uncertain)
      end
    end

    it 'does not apply same-rate mixed candidates at P3 scope' do
      result = call_service(
        receipt: {
          subtotal_amount: 200,
          tax_amount: 20,
          total_amount: 220
        },
        receipt_items: [
          { line_total: 110, tax_rate: BigDecimal('0.1') },
          { line_total: 100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
        expect(result[:calculation_profile_candidates]).to include(
          hash_including(
            same_rate_item_amount_basis_assignments: contain_exactly(
              hash_including(assignment_scope: :item, item_indices: [0], basis: :tax_included),
              hash_including(assignment_scope: :item, item_indices: [1], basis: :tax_excluded)
            )
          )
        )
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_inconsistencies]).not_to include(:calculation_profile_uncertain)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'returns price tax inclusion uncertainty as a warning without requiring review' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_101
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit: '個',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_mismatch_codes]).to include('PRICE_TAX_INCLUSION_UNCERTAIN')
        expect(result[:warning_reasons]).to include('price_tax_inclusion_uncertain')
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'converts 100 percent discount_rate into zero line_total' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 310,
            quantity: 1,
            quantity_unit: '個',
            discount_rate: 100,
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(310)
        expect(item[:discount_amount]).to eq(310)
        expect(item[:line_total]).to eq(0)
        expect(result[:resolved][:total]).to eq(0)
      end
    end

    it 'infers discount_rate from OCR discount_amount when rate is missing' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 310,
            quantity: 1,
            quantity_unit: '個',
            original_line_total: 310,
            discount_amount: 155,
            line_total: 155,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :analysis
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:discount_amount]).to eq(155)
        expect(item[:discount_rate]).to eq(BigDecimal('0.5'))
        expect(item[:line_total]).to eq(155)
      end
    end

    it 'fills line_total from price multiplied by decimal quantity when line_total is nil' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: '個', line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'parses decimal comma quantity as decimal' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: '0,300', line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit: '個' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
      end
    end

    it 'does not fill line_total from price multiplied by quantity for measurement unit' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit: 'kg' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(0)
        expect(result[:resolved][:total]).not_to eq(4_320)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'keeps explicit line_total for measurement unit' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), line_total: 4_320, tax_rate: BigDecimal('0.1'), quantity_unit: 'kg' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'does not fill line_total from price multiplied by quantity for unknown unit' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit: '束' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:line_total]).to eq(0)
        expect(result[:resolved][:total]).not_to eq(4_320)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'parses comma separated amount strings without truncating at the comma' do
      result = call_service(
        receipt: {
          total_amount: '5,000'
        },
        receipt_items: [
          { price: '1,234', quantity: 2, line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit: '個' },
          { price: nil, quantity: 1, line_total: '4,320', tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:line_total]).to eq(2_468)
        expect(result[:computed][:items].second[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(6_788)
      end
    end

    it 'parses comma separated receipt total as yen amount when no items exist' do
      result = call_service(
        receipt: {
          total_amount: '5,000'
        },
        receipt_items: [],
        context: :manual
      )

      expect(result[:resolved][:total]).to eq(5_000)
    end

    it 'marks item_total_mismatch when price multiplied by quantity clearly conflicts with line_total' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 300, quantity: 2, line_total: 500, tax_rate: BigDecimal('0.1'), quantity_unit: '個' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'does not mark item_total_mismatch for measurement unit when line_total conflicts with price times quantity' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: 'kg', line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not mark item_total_mismatch for unknown unit when line_total conflicts with price times quantity' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 300, quantity: 2, quantity_unit: '束', line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not mark item_total_mismatch when price appears tax-exclusive and line_total is tax-included' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 100, quantity: 1, line_total: 110, tax_rate: BigDecimal('0.1'), quantity_unit: '個' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(110)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'marks insufficient_data when neither line_total nor price is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: nil, quantity: 1, line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:inconsistencies]).to include(:insufficient_data)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'does not need review for an explicit zero amount item' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:inconsistencies]).not_to include(:insufficient_data)
        expect(result[:warning_inconsistencies]).not_to include(:zero_amount_item_incomplete)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats zero line_total without price and quantity as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [
          { price: nil, quantity: nil, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:zero_amount_item_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:insufficient_data)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review for normal items mixed with zero amount items' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 500, quantity: 1, line_total: 500, tax_rate: BigDecimal('0.1') },
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') },
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:insufficient_data)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review when only zero amount items exist and receipt total is zero' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:blocking_inconsistencies]).to be_empty
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'marks blocking mismatch when only zero amount items exist but receipt total is positive' do
      result = call_service(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'treats tax_detail with missing net_amount as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: nil, amount: 9 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats tax_detail with missing amount as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: nil }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats tax_detail with missing rate as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: nil, net_amount: 99, amount: 9 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats clearly partial tax_details as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 218,
          subtotal_amount: 200,
          tax_amount: 18,
          tax_rate: nil
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_partial)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not resolve total from partial tax_details when item_total is larger' do
      result = call_service(
        receipt: {
          tax_rate: nil
        },
        receipt_items: [
          { line_total: 130, tax_rate: BigDecimal('0.08') },
          { line_total: 140, tax_rate: BigDecimal('0.08') },
          { line_total: 300, tax_rate: BigDecimal('0.1') },
          { line_total: 490, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21 },
          { rate: BigDecimal('0.1'), net_amount: 300, amount: 30 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(1_110)
        expect(result[:resolved][:total]).not_to eq(621)
        expect(result[:resolved][:tax_rate]).to be_nil
        expect(result[:computed][:item_amount_basis]).to eq(:line_total_as_recorded)
        expect(result[:calculation_profile]).not_to include(item_amount_basis: :line_total_as_net)
        expect(result[:calculation_profile_candidates].map { |candidate| candidate[:profile][:item_amount_basis] }).to include(:mixed_by_tax_rate_group)
        expect(result[:warning_inconsistencies]).to include(:tax_detail_partial)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'keeps complete and clearly conflicting tax_details as blocking mismatch' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 78, amount: 30 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'treats item tax rate group uncertainty as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 99, amount: 9 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:item_tax_rate_group_uncertain)
        expect(result[:warning_reasons]).to include('item_tax_rate_group_uncertain')
        expect(result[:blocking_inconsistencies]).not_to include(:item_tax_rate_group_uncertain)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats item net total plus tax_details as external tax when receipt total matches net plus tax' do
      result = call_service(
        receipt: {
          total_amount: 500
        },
        receipt_items: [
          { line_total: 455, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45, description: '外税 10%' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 455,
          tax: 45,
          total: 500,
          tax_rate: BigDecimal('0.1')
        )
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
