require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep do
  subject(:finalize_step) do
    described_class.new(receipt:, decision: instance_double(Receipts::Processing::Contracts::FinalizeDecision))
  end

  let(:receipt) { create(:receipt, :processing, :with_image) }
  let(:source_item) do
    {
      raw_text: '検証品',
      price: 100,
      quantity: BigDecimal('2'),
      quantity_unit_code: 'each',
      original_line_total: 200,
      line_total: 200,
      tax_rate: BigDecimal('0.1'),
      position_index: 1,
      needs_review: false,
      review_reasons: []
    }
  end

  def final_result(item: source_item, **receipt_values)
    ReceiptAmountService.call(
      receipt: { subtotal_amount: 200, tax_amount: 20, total_amount: 220, **receipt_values },
      receipt_items: [ item ],
      receipt_tax_details: [],
      context: :analysis
    )
  end

  def persist(result, items: [ source_item ], receipt_overrides: {})
    finalize_step.instance_variable_set(:@final_amount_result, result)
    resolved = result.fetch(:resolved)
    finalize_step.send(
      :persist_result_full!,
      receipt_attributes: {
        subtotal_amount: resolved[:subtotal],
        tax_amount: resolved[:tax],
        total_amount: resolved[:total],
        **receipt_overrides
      },
      items_attributes: items,
      payments_attributes: [],
      tax_details_attributes: [],
      adjustments_attributes: []
    )
  end

  it '最終accepted結果の適用条件だけをanalysis由来で保存する' do
    result = final_result
    expect(result.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_excluded')

    persist(result)

    expect(receipt.reload.calculation_settings).to eq(result.fetch(:applied_calculation_settings))
    expect(receipt.calculation_settings.values.grep(Hash)).to all(include('origin' => 'analysis'))
  end

  it 'rejectまたはno-safeを記録できる計算条件へ昇格しない' do
    result = final_result
    result[:selected_candidate_status] = 'rejected'
    result[:amount_engine][:no_safe_candidate] = true

    persist(result)

    expect(receipt.reload.calculation_settings).to be_nil
    expect(receipt.receipt_items.sole.gross_line_total).to be_nil
  end

  it '最終Receipt値がAmount resolvedと異なる保護経路では条件を補わない' do
    persist(final_result, receipt_overrides: { total_amount: 221 })

    expect(receipt.reload.calculation_settings).to be_nil
  end

  it '後処理でresolvedだけが保護金額へ変わった場合にcandidateの条件を採用済みとしない' do
    result = final_result
    result[:resolved][:total] = 221

    persist(result)

    expect(receipt.reload.calculation_settings).to be_nil
  end

  it '既存条件を同一処理の設定値で上書きしない' do
    saved = { 'schema_version' => 1, 'tax_rounding_mode' => { 'value' => 'ceil', 'origin' => 'manual' } }
    receipt.update!(calculation_settings: saved)

    persist(final_result)

    expect(receipt.reload.calculation_settings).to eq(saved)
  end

  it 'provider側の任意の新fieldをtrusted結果の代用にしない' do
    result = final_result
    result.delete(:applied_calculation_settings)
    malicious_settings = { 'schema_version' => 1, 'tax_rounding_mode' => { 'value' => 'ceil', 'origin' => 'manual' } }
    persist(
      result,
      items: [ source_item.merge(input_tax_inclusion: 'net', tax_inclusion_origin: 'manual', gross_line_total: 999) ],
      receipt_overrides: { calculation_settings: malicious_settings }
    )

    item = receipt.reload.receipt_items.sole
    expect(receipt.calculation_settings).to be_nil
    expect(item.input_tax_inclusion).to be_nil
    expect(item.tax_inclusion_origin).to be_nil
    expect(item.gross_line_total).not_to eq(999)
  end

  it 'ItemAmountsの税込projectionをsource列とは別に保存する' do
    result = final_result
    persisted = finalize_step.send(:apply_amount_item_totals, [ source_item ], result.dig(:computed, :items))

    persist(result, items: persisted)

    item = receipt.reload.receipt_items.sole
    expect(item.gross_line_total).to eq(220)
    expect(item.line_total).to eq(persisted.sole[:line_total])
    expect(item.input_tax_inclusion).to be_nil
  end

  it 'ItemAmounts以外の税抜count値を税込projectionと取り違えない' do
    result = final_result
    result[:amount_engine][:selected_basis] = 'printed_tax_details_net'
    result[:amount_engine][:selected_candidate][:basis] = 'printed_tax_details_net'
    result[:computed][:amount_engine_basis] = 'printed_tax_details_net'
    result[:computed][:items] = [ source_item ]

    persist(result)

    expect(receipt.reload.receipt_items.sole.gross_line_total).to be_nil
  end

  it '信頼済みcount sourceの税抜入力と税込projectionを別々に記録する' do
    source = source_item.merge(pricing_source_kind: 'count_unit_price')
    result = final_result(item: source)
    finalize_step.instance_variable_set(:@final_amount_result, result)

    attributes = finalize_step.send(:final_item_calculation_attributes, [ source ], source_count: 1).sole

    expect(attributes).to include(
      price: 100,
      original_line_total: 200,
      line_total: 200,
      input_tax_inclusion: 'net',
      tax_inclusion_origin: 'analysis',
      gross_line_total: 220
    )
  end

  it '信頼済みexplicit sourceは非乗算の税込入力として記録する' do
    source = source_item.merge(pricing_source_kind: 'explicit_line_total', price: nil, quantity: BigDecimal('3'))
    result = final_result(item: source, total_amount: 200, subtotal_amount: 182, tax_amount: 18)
    finalize_step.instance_variable_set(:@final_amount_result, result)

    attributes = finalize_step.send(:final_item_calculation_attributes, [ source ], source_count: 1).sole

    expect(attributes).to include(
      price: nil,
      quantity: BigDecimal('3'),
      original_line_total: 200,
      line_total: 200,
      input_tax_inclusion: 'gross',
      tax_inclusion_origin: 'analysis',
      gross_line_total: 200
    )
  end

  it '計算結果と保存sourceのmodeが異なる場合は入力basisを付与しない' do
    result = final_result
    finalize_step.instance_variable_set(:@final_amount_result, result)
    source = source_item.merge(pricing_source_kind: 'count_unit_price')

    attributes = finalize_step.send(:final_item_calculation_attributes, [ source ], source_count: 1).sole

    expect(attributes).not_to have_key(:input_tax_inclusion)
  end

  it '明細の正規化で欠落した行を別indexのprojectionへ関連付けない' do
    result = final_result
    result[:computed][:items] = [ source_item, source_item.merge(line_total: 999) ]

    persist(result, items: [ source_item.merge(price: -1), source_item ])

    expect(receipt.reload.receipt_items.sole.gross_line_total).to be_nil
  end

  it '子行保存失敗時はReceipt固有条件も同じtransactionでrollbackする' do
    allow(receipt.receipt_items).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(ReceiptItem.new))

    expect { persist(final_result) }.to raise_error(ActiveRecord::RecordInvalid)

    expect(receipt.reload.calculation_settings).to be_nil
  end
end
