require 'rails_helper'

RSpec.describe 'OCR item calculation mode persistence' do
  def ocr_fixture(name)
    raw = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def finalize_decision(strategy, error_code: nil, ocr_result: nil)
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: strategy.to_s,
      error_code: error_code,
      error_message: error_code,
      receipt_attributes: {},
      ocr_result:,
      ai_result: nil,
      metadata: {}
    )
  end

  def ai_result
    {
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_attributes: {},
      receipt_items_attributes: []
    }
  end

  def build_ready_run(receipt, fixture:, strategy:, source: 'upload', parent_run: nil)
    run = Receipts::Processing.start(receipt: receipt, source: source, parent_run: parent_run).run
    Receipts::Processing.record_ocr_snapshot(run, ocr_fixture(fixture))
    Receipts::Processing.record_ai_normalized_result(run, ai_result) if strategy == :ai_success
    Receipts::Processing.record_finalize_decision(
      run,
      finalize_decision(strategy, error_code: strategy == :ai_fallback ? 'ai_unavailable' : nil)
    )
    run.reload
  end

  it 'OCR-onlyでconfirmed count sourceを現在金額を変えず保存し、statusは従来どおりreview_neededにする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)

    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(receipt.reload).to have_attributes(
        status: 'review_needed',
        subtotal_amount: 700,
        tax_amount: 70,
        total_amount: 770
      )
      expect(receipt.receipt_items.order(:position_index)).to all(
        have_attributes(
          pricing_source_kind: 'count_unit_price',
          quantity: BigDecimal('1'),
          quantity_unit_code: 'item'
        )
      )
      expect(receipt.receipt_items.order(:position_index).pluck(:price, :original_line_total, :line_total)).to eq(
        [ 220, 132, 110, 308 ].map { |amount| [ amount, amount, amount ] }
      )
      expect(receipt.amount_calculation_profile.dig('profile', 'receipt_tax_basis')).to eq('total_includes_tax')
      expect(run.reload).to have_attributes(status: 'succeeded', stage: 'completed')
    end
  end

  it 'AI successも同じtyped OCR sourceからcount authorityを保存する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ai_success)

    Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(770)
      expect(receipt.receipt_items.order(:position_index).pluck(:pricing_source_kind).uniq).to eq(
        [ 'count_unit_price' ]
      )
      expect(run.reload.status).to eq('succeeded')
    end
  end

  it 'AI fallbackでstrong printed totalをexplicit authorityとして0円明細も欠損させない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'receipt_sample', strategy: :ai_fallback)

    Receipts::Processing.run_finalize(run)

    items = receipt.reload.receipt_items.order(:position_index)
    aggregate_failures do
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 1130)
      expect(items.pluck(:pricing_source_kind).uniq).to eq([ 'explicit_line_total' ])
      expect(items.pluck(:price)).to all(be_nil)
      expect(items.pluck(:original_line_total, :line_total)).to eq(
        [ 580, 200, 250, 100, 0 ].map { |amount| [ amount, amount ] }
      )
      expect(run.reload.status).to eq('succeeded')
    end
  end

  it '親runを持つ再解析ではstable item lineageなしに新しいauthorityを上書きしない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
    run = build_ready_run(
      receipt,
      fixture: 'single_tax_receipt',
      strategy: :ocr_only,
      source: 'admin_retry',
      parent_run: parent_run
    )

    Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(receipt.reload.receipt_items).to all(have_attributes(pricing_source_kind: nil))
      expect(receipt.total_amount).to eq(770)
    end
  end

  it 'inline OCR結果を優先するdirect finalizeへ保存済みsnapshotのauthorityを混在させない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    inline_ocr_result = ocr_fixture('single_tax_receipt')

    Receipts::Processing::Pipeline::FinalizeStep.call(
      receipt:,
      decision: finalize_decision(:ocr_only, ocr_result: inline_ocr_result),
      run:
    )

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(770)
      expect(receipt.receipt_items).to all(have_attributes(pricing_source_kind: nil))
    end
  end

  it 'Amount失敗時も従来どおりbounded BuildParams snapshotを先に記録する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    allow(ReceiptAmountService).to receive(:call).and_raise('amount failed')

    expect do
      Receipts::Processing::Pipeline::FinalizeStep.call(
        receipt:,
        decision: finalize_decision(:ocr_only),
        run:
      )
    end.to raise_error('amount failed')

    aggregate_failures do
      expect(run.reload.metadata['build_params_snapshot']).to be_present
      expect(receipt.reload.status).to eq('processing')
      expect(receipt.receipt_items).to be_empty
    end
  end

  it '同じrunのfinalize再実行では明細を重複作成しない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)

    first_result = Receipts::Processing.run_finalize(run)
    item_ids = receipt.reload.receipt_items.order(:position_index).ids
    second_result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(first_result.next_step).to eq(:done)
      expect(second_result).to have_attributes(next_step: :skipped, skip_reason: :terminal_run)
      expect(receipt.reload.receipt_items.order(:position_index).ids).to eq(item_ids)
      expect(receipt.receipt_items).to all(have_attributes(pricing_source_kind: 'count_unit_price'))
    end
  end

  it 'final result保存失敗時は計算方式authorityと明細を同じtransactionでrollbackする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    original_total = receipt.total_amount
    allow(Receipts::Processing).to receive(:record_final_result).and_raise('summary write failed')

    expect { Receipts::Processing.run_finalize(run) }.to raise_error('summary write failed')

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.total_amount).to eq(original_total)
      expect(receipt.status).to eq('failed')
      expect(run.reload.status).to eq('failed')
      expect(run.final_result_summary).to be_blank
    end
  end

  it '永続化時のtrusted source driftはFinalizeStep単体でも全明細をrollbackする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    original_total = receipt.total_amount
    trusted_normalizations = 0
    normalizer = Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer
    allow(normalizer).to receive(:items).and_wrap_original do |original, items, **options|
      original.call(items, **options).tap do |normalized|
        next if Array(options[:trusted_item_calculation_mode_sources]).empty?

        trusted_normalizations += 1
        normalized.each { |item| item.delete(:pricing_source_kind) } if trusted_normalizations == 2
      end
    end

    expect do
      Receipts::Processing::Pipeline::FinalizeStep.call(
        receipt:,
        decision: finalize_decision(:ocr_only),
        run:
      )
    end.to raise_error(
      Receipts::Processing::AnalysisError,
      'item_calculation_mode_persistence_mismatch'
    )

    aggregate_failures do
      expect(trusted_normalizations).to eq(2)
      expect(receipt.reload).to have_attributes(status: 'processing', total_amount: original_total)
      expect(receipt.receipt_items).to be_empty
    end
  end
end
