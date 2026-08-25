require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator do
  def fixture_context(name, mutate_raw: nil)
    raw = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)
    mutate_raw&.call(raw)
    parsed = Ocr::ResponseParser.new(response: raw, provider: :fixture).call
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(parsed)
    ocr_result = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(
      JSON.parse(JSON.generate(snapshot))
    )
    params = Analysis.enforce_ownership_consistency(
      params: Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: nil)
    )

    {
      ocr_result: ocr_result,
      params: params,
      amount_result: amount_for(params)
    }
  end

  def amount_for(params)
    ReceiptAmountService.call(
      receipt: params[:receipt_attributes],
      receipt_items: params[:receipt_items_attributes],
      receipt_tax_details: params[:receipt_tax_details_attributes],
      receipt_adjustments: params[:receipt_adjustments_attributes],
      receipt_payments: params[:receipt_payments_attributes],
      context: :analysis
    )
  end

  def result_for(context, **overrides, &amount_calculator)
    described_class.call(
      params: overrides.fetch(:params, context.fetch(:params)),
      ocr_result: overrides.fetch(:ocr_result, context.fetch(:ocr_result)),
      preliminary_amount_result: overrides.fetch(:amount_result, context.fetch(:amount_result)),
      automatic_application_allowed: overrides.fetch(:automatic_application_allowed, true),
      item_price_limit: overrides.fetch(:item_price_limit, 999_999_999),
      item_line_total_limit: overrides.fetch(:item_line_total_limit, 999_999_999),
      &(amount_calculator || method(:amount_for))
    )
  end

  def make_all_printed_totals_mismatch(raw)
    analyze_result = raw.fetch('analyzeResult')
    analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray').each do |item|
      total = item.dig('valueObject', 'TotalPrice')
      current = total.dig('valueCurrency', 'amount')
      replacement = current + 1
      content = "¥#{replacement}"
      raise 'replacement must preserve fixture span length' unless content.length == total.fetch('content').length

      span = total.fetch('spans').sole
      parent_offset = item.fetch('spans').sole.fetch('offset')
      analyze_result.fetch('content')[span.fetch('offset'), span.fetch('length')] = content
      item.fetch('content')[span.fetch('offset') - parent_offset, span.fetch('length')] = content
      total['content'] = content
      total.fetch('valueCurrency')['amount'] = replacement
    end
  end

  it '同一Itemの単価×明示数量が印字額と一致する場合は現在金額を変えずcount authorityを適用する' do
    context = fixture_context('single_tax_receipt')
    before = context.fetch(:params).deep_dup

    result = result_for(context)

    aggregate_failures do
      expect(result).to be_applied
      expect(result.selections.size).to eq(4)
      expect(result.selections).to all(have_attributes(pricing_source_kind: 'count_unit_price'))
      expect(result.params.fetch(:receipt_items_attributes).map do |item|
        item.slice(:pricing_source_kind, :price, :quantity, :quantity_unit_code, :original_line_total, :line_total)
      end).to eq(
        [ 220, 132, 110, 308 ].map do |amount|
          {
            pricing_source_kind: 'count_unit_price',
            price: amount,
            quantity: BigDecimal('1'),
            quantity_unit_code: 'item',
            original_line_total: amount,
            line_total: amount
          }
        end
      )
      expect(result.amount_result[:resolved]).to eq(context.dig(:amount_result, :resolved))
      expect(result.amount_result.dig(:computed, :receipt_tax_basis)).to eq(:tax_added_to_subtotal)
      expect(result.params).not_to equal(context.fetch(:params))
      expect(context.fetch(:params)).to eq(before)
    end
  end

  it 'proposal集合は全Item分を一括して1回だけ再検証する' do
    context = fixture_context('single_tax_receipt')
    allow(described_class::PROPOSAL_CONTRACT).to receive(:from_snapshot).and_call_original

    result = result_for(context)

    aggregate_failures do
      expect(result).to be_applied
      expect(described_class::PROPOSAL_CONTRACT).to have_received(:from_snapshot).once
    end
  end

  it '強くItemに帰属する印字合計だけなら0円を含めexplicit authorityを適用する' do
    context = fixture_context('receipt_sample')

    result = result_for(context)

    aggregate_failures do
      expect(result).to be_applied
      expect(result.selections.size).to eq(5)
      expect(result.params.fetch(:receipt_items_attributes).map do |item|
        [ item[:pricing_source_kind], item[:price], item[:original_line_total], item[:line_total] ]
      end).to eq(
        [ 580, 200, 250, 100, 0 ].map { |amount| [ 'explicit_line_total', nil, amount, amount ] }
      )
      expect(result.amount_result[:resolved]).to eq(context.dig(:amount_result, :resolved))
    end
  end

  it 'formulaと印字額が全て不一致ならreviewableをauthorityにせずAmountを再実行しない' do
    context = fixture_context('single_tax_receipt', mutate_raw: method(:make_all_printed_totals_mismatch))
    amount_called = false

    result = result_for(context) do
      amount_called = true
      raise 'Amount must not run for reviewable-only decisions'
    end

    aggregate_failures do
      expect(amount_called).to be(false)
      expect(result).not_to be_applied
    end
  end

  it 'countの税semanticsを保存済みprofileから再現できない場合は適用しない' do
    context = fixture_context('single_tax_receipt')
    amount_result = context.fetch(:amount_result).deep_dup
    amount_result[:calculation_profile] = {
      receipt_tax_basis: :tax_added_to_subtotal,
      item_amount_basis: :line_total_as_recorded
    }

    result = result_for(context, amount_result: amount_result)

    aggregate_failures do
      expect(result).not_to be_applied
      expect(result.params).to equal(context.fetch(:params))
      expect(result.amount_result).to equal(amount_result)
    end
  end

  it '今回はstructured reference proposalをA1に偽装して適用しない' do
    context = fixture_context('ocr_azure_item_calculation_reference_gross_anonymized')

    result = result_for(context)

    aggregate_failures do
      expect(result).not_to be_applied
      expect(result.params.fetch(:receipt_items_attributes).sole[:pricing_source_kind]).to be_nil
    end
  end

  it '対象Itemにdiscount sourceがあるexplicit proposalは自動適用しない' do
    context = fixture_context('receipt_sample')
    params = context.fetch(:params).deep_dup
    params.fetch(:receipt_items_attributes).first.merge!(discount_amount: 1, line_total: 579)
    amount_result = amount_for(params)

    result = result_for(context, params: params, amount_result: amount_result)

    aggregate_failures do
      expect(result).to be_applied
      expect(result.params.fetch(:receipt_items_attributes).first[:pricing_source_kind]).to be_nil
      expect(result.params.fetch(:receipt_items_attributes).drop(1)).to all(
        include(pricing_source_kind: 'explicit_line_total')
      )
      expect(result.amount_result[:resolved]).to eq(amount_result[:resolved])
    end
  end

  it 'item identityが重複する場合は部分適用せずfail-neutralにする' do
    context = fixture_context('single_tax_receipt')
    params = context.fetch(:params).deep_dup
    params.fetch(:receipt_items_attributes)[1][:ocr_item_identity] =
      params.fetch(:receipt_items_attributes)[0][:ocr_item_identity]

    amount_called = false
    result = result_for(context, params: params) do
      amount_called = true
      raise 'Amount must not run for duplicate identity'
    end

    aggregate_failures do
      expect(amount_called).to be(false)
      expect(result).not_to be_applied
    end
  end

  it '保存先positionが重複する場合は部分適用せずfail-neutralにする' do
    context = fixture_context('single_tax_receipt')
    params = context.fetch(:params).deep_dup
    params.fetch(:receipt_items_attributes)[1][:position_index] =
      params.fetch(:receipt_items_attributes)[0][:position_index]

    amount_called = false
    result = result_for(context, params:) do
      amount_called = true
      raise 'Amount must not run for duplicate position'
    end

    aggregate_failures do
      expect(amount_called).to be(false)
      expect(result).not_to be_applied
    end
  end

  it 'typed sourceとBuildParamsが一致しない場合は部分適用せずfail-neutralにする' do
    context = fixture_context('single_tax_receipt')
    params = context.fetch(:params).deep_dup
    params.fetch(:receipt_items_attributes).first[:price] = 221

    amount_called = false
    result = result_for(context, params: params) do
      amount_called = true
      raise 'Amount must not run for mismatched source'
    end

    aggregate_failures do
      expect(amount_called).to be(false)
      expect(result).not_to be_applied
    end
  end

  it '最終Amountでreceipt totalが1円でも変わる場合は全適用を破棄する' do
    context = fixture_context('single_tax_receipt')
    drifted = context.fetch(:amount_result).deep_dup
    drifted[:resolved][:total] += 1

    result = result_for(context) { |_params| drifted }

    aggregate_failures do
      expect(result).not_to be_applied
      expect(result.params).to equal(context.fetch(:params))
      expect(result.amount_result).to equal(context.fetch(:amount_result))
    end
  end

  it '非選択Itemのcomputed priceだけが変わる場合も全適用を破棄する' do
    context = fixture_context('receipt_sample')
    params = context.fetch(:params).deep_dup
    params.fetch(:receipt_items_attributes).first.merge!(discount_amount: 1, line_total: 579)
    amount_result = amount_for(params)

    result = result_for(context, params:, amount_result:) do |candidate_params|
      amount_for(candidate_params).deep_dup.tap do |drifted|
        drifted.dig(:computed, :items).first[:price] += 1
      end
    end

    aggregate_failures do
      expect(result).not_to be_applied
      expect(result.params).to equal(params)
      expect(result.amount_result).to equal(amount_result)
    end
  end

  it 'canonical OCR snapshotがない場合は例外にせず適用しない' do
    context = fixture_context('single_tax_receipt')
    amount_called = false

    result = result_for(context, ocr_result: nil) do
      amount_called = true
      raise 'Amount must not run without a canonical OCR snapshot'
    end

    aggregate_failures do
      expect(amount_called).to be(false)
      expect(result).not_to be_applied
      expect(result.params).to equal(context.fetch(:params))
    end
  end

  it '自動適用が許可されないrunではproposalを判定してもauthorityを適用しない' do
    context = fixture_context('single_tax_receipt')
    amount_called = false

    result = result_for(context, automatic_application_allowed: false) do
      amount_called = true
      raise 'Amount must not run when automatic application is disabled'
    end

    aggregate_failures do
      expect(amount_called).to be(false)
      expect(result).not_to be_applied
    end
  end
end
