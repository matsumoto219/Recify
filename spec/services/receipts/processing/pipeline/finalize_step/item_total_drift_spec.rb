require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep do
  subject(:finalize_step) do
    described_class.new(receipt: build_stubbed(:receipt), decision: instance_double(Receipts::Processing::Contracts::FinalizeDecision))
  end

  def drift_reasons(
    item_total:,
    subtotal: 1_745,
    total: 1_884,
    item_basis: 'line_total_as_net',
    receipt_basis: 'tax_added_to_subtotal',
    adjustment: 0,
    payment_adjustment: 0
  )
    params = { receipt_items_attributes: [ { line_total: item_total } ] }
    amount_result = {
      calculation_profile: { item_amount_basis: item_basis, receipt_tax_basis: receipt_basis },
      amount_engine: { selected_basis: 'external_tax_from_receipt' },
      computed: {
        item_amount_basis: item_basis,
        receipt_tax_basis: receipt_basis,
        items: [ { line_total: item_total } ],
        adjusted_item_total: item_total + adjustment + payment_adjustment,
        purchase_adjustment_total: adjustment,
        payment_adjustment_total: payment_adjustment
      },
      resolved: { subtotal: subtotal, total: total, tax: total - subtotal },
      tax_details: [ { net_amount: subtotal, amount: total - subtotal } ]
    }

    review_reasons_for(params, amount_result)
  end

  def review_reasons_for(params, amount_result)
    finalize_step.send(
      :item_total_drift_review_reasons,
      params,
      amount_result,
      ai_result: { receipt_items_attributes: [ { index: 0 } ] }
    )
  end

  it '税抜明細の不一致を税込合計への近さで解消しない' do
    expect(drift_reasons(item_total: 1_957)).to eq([ 'item_total_mismatch' ])
  end

  it '税込明細の不一致を税抜小計への近さで解消しない' do
    expect(drift_reasons(
      item_total: 1_750,
      item_basis: 'line_total_as_recorded',
      receipt_basis: 'total_includes_tax'
    )).to eq([ 'item_total_mismatch' ])
  end

  it '税抜と税込の正常明細は対応する金額で照合する' do
    aggregate_failures do
      expect(drift_reasons(item_total: 1_745)).to eq([])
      expect(drift_reasons(
        item_total: 1_884,
        item_basis: 'line_total_as_recorded',
        receipt_basis: 'total_includes_tax'
      )).to eq([])
    end
  end

  it 'as-recordedの明細をreceiptの外税基準だけで税抜と推測しない' do
    expect(drift_reasons(item_total: 1_957, item_basis: 'line_total_as_recorded')).to eq([])
  end

  it 'receipt割引後の明細合計だけを同じ割引段階で照合する' do
    aggregate_failures do
      expect(drift_reasons(item_total: 1_884, adjustment: -300)).to eq([ 'item_total_mismatch' ])
      expect(drift_reasons(item_total: 2_045, adjustment: -300)).to eq([])
    end
  end

  it '支払調整を購入明細の不一致の解消に使わない' do
    expect(drift_reasons(item_total: 1_584, payment_adjustment: 161)).to eq([ 'item_total_mismatch' ])
  end

  it '100円の既存許容差の直前・一致・直後を維持する' do
    [ [ 99, [] ], [ 100, [] ], [ 101, [ 'item_total_mismatch' ] ] ].each do |delta, expected|
      expect(drift_reasons(item_total: 10_000 + delta, subtotal: 10_000, total: 10_800)).to eq(expected)
    end
  end

  it '1%の既存許容差の直前・一致・直後を維持する' do
    [ [ 199, [] ], [ 200, [] ], [ 201, [ 'item_total_mismatch' ] ] ].each do |delta, expected|
      expect(drift_reasons(item_total: 20_000 + delta, subtotal: 20_000, total: 21_600)).to eq(expected)
    end
  end

  it 'mixed profileの金額基準を均一税抜と推測しない' do
    expect(drift_reasons(item_total: 1_884, item_basis: 'mixed_by_tax_rate_group')).to eq([])
  end

  it '税抜sourceを税込computedへ投影するitems candidateは従来どおり対象外にする' do
    items = [
      {
        pricing_source_kind: 'count_unit_price',
        price: 1_200,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 1_200,
        line_total: 1_200,
        tax_rate: BigDecimal('0.1')
      }
    ]
    amount_result = ReceiptAmountService.call(
      receipt: { subtotal_amount: 1_200, tax_amount: 120, total_amount: 1_320, tax_rate: BigDecimal('0.1') },
      receipt_items: items,
      receipt_tax_details: [],
      context: :analysis
    )

    aggregate_failures do
      expect(amount_result.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_excluded')
      expect(amount_result.dig(:computed, :items).sole[:line_total]).to eq(1_320)
      expect(review_reasons_for({ receipt_items_attributes: items }, amount_result)).to eq([])
    end
  end

  it 'countとreferenceが混在する場合はitemごとのgross/netを均一基準へ変更しない' do
    %w[gross net].each do |tax_inclusion|
      items = [
        {
          pricing_source_kind: 'count_unit_price',
          price: 200,
          quantity: 1,
          quantity_unit_code: 'each',
          original_line_total: 200,
          line_total: 200,
          tax_rate: BigDecimal('0.2')
        },
        {
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: '1200',
          reference_quantity: '1',
          reference_quantity_unit_code: 'liter',
          reference_price_tax_inclusion: tax_inclusion,
          quantity: '1',
          quantity_unit_code: 'liter',
          original_line_total: 1_200,
          line_total: 1_200,
          tax_rate: BigDecimal('0.2')
        }
      ]
      params = { receipt_items_attributes: items }
      amount_result = {
        calculation_profile: { item_amount_basis: 'line_total_as_net', receipt_tax_basis: 'tax_added_to_subtotal' },
        amount_engine: { selected_basis: 'printed_tax_details_net' },
        computed: {
          item_amount_basis: 'line_total_as_net',
          receipt_tax_basis: 'tax_added_to_subtotal',
          items: [ { line_total: 200 }, { line_total: tax_inclusion == 'net' ? 1_440 : 1_200 } ],
          adjusted_item_total: tax_inclusion == 'net' ? 1_640 : 1_400,
          purchase_adjustment_total: 0
        },
        resolved: { subtotal: 1_400, tax: 280, total: 1_680 },
        tax_details: [ { net_amount: 1_400, amount: 280 } ]
      }

      aggregate_failures(tax_inclusion) do
        expect(finalize_step.send(:item_total_drift_comparable_totals, params, amount_result)).to be_nil
        expect(review_reasons_for(params, amount_result)).to eq([])
      end
    end
  end

  it '税基準を一意に決められない購入調整は既存の割引段階の照合を維持する' do
    [ [ 'receipt_discount', 'discount', -3_000 ], [ 'service_charge', 'surcharge', 3_000 ] ].each do |kind, sign, adjustment|
      items = [
        {
          price: 11_000,
          quantity: 1,
          original_line_total: 11_000,
          discount_amount: 1_000,
          line_total: 10_000,
          tax_rate: BigDecimal('0.1')
        }
      ]
      subtotal = 10_000 + adjustment
      amount_result = ReceiptAmountService.call(
        receipt: { total_amount: subtotal * 11 / 10 },
        receipt_items: items,
        receipt_tax_details: [ { rate: BigDecimal('0.1'), net_amount: subtotal, amount: subtotal / 10 } ],
        receipt_adjustments: [ { kind: kind, sign: sign, amount: adjustment.abs, tax_rate: BigDecimal('0.1'), source: 'ocr' } ],
        context: :analysis
      )

      aggregate_failures(sign) do
        expect(amount_result.dig(:amount_engine, :selected_basis)).to be_in(%w[printed_tax_details_net external_tax_from_receipt])
        expect(amount_result.dig(:computed, :receipt_tax_basis)).to eq(:tax_added_to_subtotal)
        expect(amount_result.dig(:computed, :purchase_adjustment_total)).to eq(adjustment)
        expect(amount_result.dig(:computed, :items).sum { |item| item[:line_total] }).to eq(10_000)
        expect(finalize_step.send(:item_total_drift_comparable_totals, { receipt_items_attributes: items }, amount_result)).to be_nil
        expect(review_reasons_for({ receipt_items_attributes: items }, amount_result)).to eq([])
      end
    end
  end
end
