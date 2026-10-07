require 'rails_helper'

RSpec.describe ReceiptAmountService, '.tax_detail_diagnostic' do
  let(:settings) do
    {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'analysis' },
      'discount_rounding_mode' => { 'value' => 'round', 'origin' => 'analysis' },
      'tax_rounding_scope' => { 'value' => 'per_tax_rate_group', 'origin' => 'analysis' }
    }
  end
  let(:receipt) { { total_amount: 110, subtotal_amount: 100, tax_amount: 10, calculation_settings: settings } }
  let(:item) do
    {
      pricing_source_kind: 'count_unit_price',
      price: 110,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: 110,
      tax_rate: BigDecimal('0.1'),
      input_tax_inclusion: 'gross'
    }
  end
  let(:tax_detail) { { rate: BigDecimal('0.1'), net_amount: 100, amount: 10, description: '外税10%' } }

  def diagnose(receipt: self.receipt, items: [ item ], tax_details: [ tax_detail ], adjustments: [])
    described_class.tax_detail_diagnostic(
      receipt: receipt,
      receipt_items: items,
      receipt_tax_details: tax_details,
      receipt_adjustments: adjustments
    )
  end

  def historical_profile
    {
      'schema_version' => 1,
      'selected_candidate_status' => 'accepted',
      'rounding_mode' => { 'tax' => 'floor', 'discount' => 'round' },
      'profile' => {
        'tax_rounding_mode' => 'floor',
        'discount_rounding_mode' => 'round',
        'receipt_tax_basis' => 'total_includes_tax',
        'item_amount_basis' => 'line_total_as_recorded'
      },
      'amount_engine' => {
        'schema_version' => 1,
        'selected_candidate_status' => 'accepted',
        'no_safe_candidate' => false,
        'selected_candidate_id' => 'items_as_tax_included/floor/per_tax_rate_group',
        'selected_basis' => 'items_as_tax_included',
        'selected_candidate' => {
          'candidate_id' => 'items_as_tax_included/floor/per_tax_rate_group',
          'basis' => 'items_as_tax_included',
          'hard_reject_reasons' => [],
          'rounding_mode' => 'floor',
          'rounding_scope' => 'per_tax_rate_group'
        }
      }
    }
  end

  it '明細から税内訳を検算できる保存条件では一致を返す' do
    result = diagnose

    expect(result).to eq(state: :consistent, reason: nil, applicable: true)
  end

  it '別の丸め方で一致しても保存済みの丸め方で税額が違えば不一致を返す' do
    saved_receipt = receipt.merge(total_amount: 111, tax_amount: 11)
    saved_item = item.merge(price: 111, line_total: 111)
    printed_detail = tax_detail.merge(amount: 11)

    result = diagnose(receipt: saved_receipt, items: [ saved_item ], tax_details: [ printed_detail ])

    expect(result).to eq(state: :mismatch, reason: :tax_detail_mismatch, applicable: true)
  end

  it '税込対象額で印字された税内訳を税抜額へ正規化して比較する' do
    printed_detail = tax_detail.merge(net_amount: 110, description: '税込10%対象')

    result = diagnose(tax_details: [ printed_detail ])

    expect(result).to eq(state: :consistent, reason: nil, applicable: true)
  end

  it '複数税率の税抜額と税額を税率ごとに比較する' do
    reduced_item = item.merge(price: 108, line_total: 108, tax_rate: BigDecimal('0.08'))
    reduced_detail = { rate: BigDecimal('0.08'), net_amount: 100, amount: 8, description: '外税8%' }
    saved_receipt = receipt.merge(total_amount: 218, subtotal_amount: 200, tax_amount: 18)

    result = diagnose(receipt: saved_receipt, items: [ item, reduced_item ], tax_details: [ reduced_detail, tax_detail ])

    expect(result).to eq(state: :consistent, reason: nil, applicable: true)
  end

  it '非課税明細を課税対象の税率別内訳に加えない' do
    untaxed_item = item.merge(price: 50, line_total: 50, tax_rate: BigDecimal('0'))
    saved_receipt = receipt.merge(total_amount: 160, subtotal_amount: 150)

    result = diagnose(receipt: saved_receipt, items: [ item, untaxed_item ])

    expect(result).to eq(state: :consistent, reason: nil, applicable: true)
  end

  it '税額0の印字内訳は引き続き判定不能として扱う' do
    zero_tax_item = item.merge(price: 1, line_total: 1)
    zero_tax_detail = tax_detail.merge(net_amount: 1, amount: 0)
    saved_receipt = receipt.merge(total_amount: 1, subtotal_amount: 1, tax_amount: 0)

    result = diagnose(receipt: saved_receipt, items: [ zero_tax_item ], tax_details: [ zero_tax_detail ])

    expect(result).to eq(state: :unavailable, reason: :incomplete_tax_details, applicable: true)
  end

  it '税内訳がない入力は診断対象外として区別する' do
    result = diagnose(tax_details: [])

    expect(result).to eq(state: :unavailable, reason: :not_applicable, applicable: false)
  end

  it '解析保存で明細の税区分が未確定でも保存用検証を緩めず表示診断のみ判定不能にする' do
    result = diagnose(items: [ item.merge(input_tax_inclusion: nil) ])

    expect(result).to eq(state: :unavailable, reason: :missing_item_tax_inclusion, applicable: true)
    expect do
      described_class.call(
        receipt: receipt,
        receipt_items: [ item.merge(input_tax_inclusion: nil) ],
        receipt_tax_details: [ tax_detail ],
        context: :edit_save
      )
    end.to raise_error(ReceiptAmountService::InvalidItemSourceError)
  end

  it '印字税内訳から欠損した明細税率を逆算して一致と判定しない' do
    count_result = diagnose(items: [ item.merge(tax_rate: nil) ])
    reference_result = diagnose(items: [ item.merge(
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: 110,
      reference_quantity: 1,
      reference_quantity_unit_code: 'each',
      reference_price_tax_inclusion: 'gross',
      tax_rate: nil
    ) ])

    expect(count_result).to eq(state: :unavailable, reason: :missing_item_tax_rate, applicable: true)
    expect(reference_result).to eq(state: :unavailable, reason: :missing_item_tax_rate, applicable: true)
  end

  it '計算方式が未記録の旧明細を印字税内訳の税率で一致と判定しない' do
    legacy_item = item.merge(pricing_source_kind: nil, input_tax_inclusion: nil, tax_rate: nil)

    result = diagnose(items: [ legacy_item ])

    expect(result).to eq(state: :unavailable, reason: :missing_item_pricing_source, applicable: true)
  end

  it '未知の明細計算方式を一致と判定しない' do
    result = diagnose(items: [ item.merge(pricing_source_kind: 'unknown') ])

    expect(result).to eq(state: :unavailable, reason: :invalid_item_pricing_source, applicable: true)
  end

  it 'reference方式の税区分が未確定なら判定不能にする' do
    reference_item = item.merge(
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: 110,
      reference_quantity: 1,
      reference_quantity_unit_code: 'each',
      reference_price_tax_inclusion: nil
    )

    result = diagnose(items: [ reference_item ])

    expect(result).to eq(state: :unavailable, reason: :missing_item_tax_inclusion, applicable: true)
  end

  it '部分的な税内訳では不一致なしと判定しない' do
    result = diagnose(tax_details: [ tax_detail.merge(net_amount: 50, amount: 5) ])

    expect(result).to include(state: :unavailable, applicable: true)
  end

  it '税率別内訳が違うときは警告扱いでも不一致を返す' do
    mismatched_rate = { rate: BigDecimal('0.08'), net_amount: 125, amount: 10, description: '外税8%' }

    result = diagnose(tax_details: [ mismatched_rate ])

    expect(result).to eq(state: :mismatch, reason: :tax_detail_rate_mismatch, applicable: true)
  end

  it '比較候補が安全でなければ税率不一致の警告だけで不一致と判定しない' do
    allow(described_class).to receive(:call).and_return(
      amount_engine: {
        no_safe_candidate: true,
        selected_candidate: {
          basis: 'items_as_tax_included',
          hard_reject_reasons: [ :negative_subtotal ],
          warnings: [ :tax_detail_rate_mismatch ]
        }
      },
      inconsistencies: [ :tax_detail_rate_mismatch ]
    )

    result = diagnose

    expect(result).to eq(state: :unavailable, reason: :no_comparable_candidate, applicable: true)
  end

  it '有効な部分設定でも過去の条件を復元できなければ判定不能にする' do
    partial = { 'schema_version' => 1, 'tax_rounding_mode' => settings.fetch('tax_rounding_mode') }

    result = diagnose(receipt: receipt.merge(calculation_settings: partial))

    expect(result).to eq(state: :unavailable, reason: :missing_calculation_settings, applicable: true)
  end

  it '有効な部分設定の不足分を保存済みの解析snapshotから復元して検算する' do
    partial = { 'schema_version' => 1, 'tax_rounding_mode' => settings.fetch('tax_rounding_mode') }

    result = diagnose(receipt: receipt.merge(calculation_settings: partial, amount_calculation_profile: historical_profile))

    expect(result).to eq(state: :consistent, reason: nil, applicable: true)
  end

  it '保存済みの解析snapshotから条件を復元できる旧レシートだけを検算する' do
    result = diagnose(receipt: receipt.merge(calculation_settings: nil, amount_calculation_profile: historical_profile))

    expect(result).to eq(state: :consistent, reason: nil, applicable: true)
  end

  it '未知の解析snapshotを現在の既定値で補わない' do
    result = diagnose(receipt: receipt.merge(calculation_settings: nil, amount_calculation_profile: historical_profile.merge('schema_version' => 2)))

    expect(result).to eq(state: :unavailable, reason: :invalid_calculation_profile, applicable: true)
  end

  it '印字税内訳を写した候補から明細計算条件を推定しない' do
    profile = historical_profile.deep_dup
    profile['amount_engine']['selected_basis'] = 'printed_tax_details_net'
    profile['amount_engine']['selected_candidate_id'] = 'printed_tax_details_net/floor'
    profile['amount_engine']['selected_candidate']['basis'] = 'printed_tax_details_net'
    profile['amount_engine']['selected_candidate']['candidate_id'] = 'printed_tax_details_net/floor'

    result = diagnose(receipt: receipt.merge(calculation_settings: nil, amount_calculation_profile: profile))

    expect(result).to eq(state: :unavailable, reason: :invalid_calculation_profile, applicable: true)
  end

  it '購入調整の税区分が未確定なら判定不能にする' do
    adjustment = { kind: 'delivery_fee', amount: 20, sign: 'surcharge', tax_rate: BigDecimal('0.1') }

    result = diagnose(adjustments: [ adjustment ])

    expect(result).to eq(state: :unavailable, reason: :missing_purchase_adjustment_tax_inclusion, applicable: true)
  end

  it '購入調整の税率を継承できないときは税内訳不一致を断定しない' do
    saved_settings = settings.merge(
      'purchase_adjustment_tax_inclusion' => { 'value' => 'gross', 'origin' => 'manual' }
    )
    saved_receipt = receipt.merge(
      subtotal_amount: 110,
      tax_amount: 11,
      total_amount: 121,
      calculation_settings: saved_settings
    )
    adjustment = { kind: 'delivery_fee', amount: 11, sign: 'surcharge', tax_rate: nil, tax_rate_source: 'unknown' }
    printed_detail = tax_detail.merge(net_amount: 110, amount: 11)

    inherited = diagnose(receipt: saved_receipt, adjustments: [ adjustment ], tax_details: [ printed_detail ])
    unresolved = diagnose(
      receipt: saved_receipt,
      items: [ item.merge(tax_rate: BigDecimal('0.08')) ],
      adjustments: [ adjustment ],
      tax_details: [ printed_detail ]
    )

    expect(inherited).to eq(state: :consistent, reason: nil, applicable: true)
    expect(unresolved).to eq(state: :unavailable, reason: :tax_detail_comparison_unavailable, applicable: true)
  end

  it '旧解析snapshotの明細basisから購入調整の税区分を推定しない' do
    adjustment = { kind: 'delivery_fee', amount: 1, sign: 'surcharge', tax_rate: BigDecimal('0.1') }
    profile = historical_profile.deep_dup
    profile['profile'].merge!(
      'receipt_tax_basis' => 'tax_added_to_subtotal',
      'item_amount_basis' => 'line_total_as_net'
    )
    saved_receipt = receipt.merge(
      total_amount: 111,
      subtotal_amount: 101,
      calculation_settings: nil,
      amount_calculation_profile: profile
    )

    result = diagnose(
      receipt: saved_receipt,
      adjustments: [ adjustment ],
      tax_details: [ tax_detail.merge(net_amount: 101) ]
    )

    expect(result).to eq(state: :unavailable, reason: :missing_purchase_adjustment_tax_inclusion, applicable: true)
  end
end
