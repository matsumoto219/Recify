require 'rails_helper'

RSpec.describe 'Reference pricing automatic adoption pipeline' do
  def destination_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def half_up_destination_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    replacements = {
      '120円/1' => '199円/2',
      '2.5' => '3.0',
      '300円' => '299円'
    }
    analyze_result['content'] = replacements.reduce(analyze_result.fetch('content')) do |content, (before, after)|
      content.sub(before, after)
    end
    page = analyze_result.fetch('pages').sole
    page.fetch('words').each do |word|
      word['content'] = replacements.fetch(word['content'], word['content'])
    end
    page.fetch('lines').each do |line|
      line['content'] = replacements.reduce(line.fetch('content')) do |content, (before, after)|
        content.sub(before, after)
      end
    end
    total = analyze_result.fetch('documents').sole.dig('fields', 'Total')
    total['content'] = '299円'
    total.fetch('valueCurrency')['amount'] = 299

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def finalize_decision
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: :ocr_only,
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
  end

  def create_setting(value)
    create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(value)
    )
  end

  def build_ready_run(receipt, ocr_result: destination_ocr_result)
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    Receipts::Processing.record_finalize_decision(run, finalize_decision)
    run.reload
  end


  it 'exact sourceを維持しHALF_UPしたderived totalだけを既存Amount境界から保存する' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, ocr_result: half_up_destination_ocr_result)

    Receipts::Processing.run_finalize(run)

    expect(receipt.reload.receipt_items.sole).to have_attributes(
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: BigDecimal('199'),
      reference_quantity: BigDecimal('2'),
      reference_quantity_unit_code: 'liter',
      quantity: BigDecimal('3'),
      quantity_unit_code: 'liter',
      price: nil,
      original_line_total: 299,
      line_total: 299
    )
  end

  it 'SystemSettingとfinal revalidationを満たすproposalだけをexisting Amount境界で採用する' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    proposal_before = run.ocr_result_snapshot.dig('adoption_proposals', 'reference_pricing').deep_dup
    writer_result = nil
    normalized_items_input = nil
    normalized_items_options = nil
    normalized_items_output = nil
    allow(Receipts::Processing::ReferencePricingAutoAdoptionWriter).to receive(:call).and_wrap_original do |original, **kwargs|
      writer_result = original.call(**kwargs)
    end
    allow(Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer).to receive(:items).and_wrap_original do |original, value, **options|
      normalized_items_input = value
      normalized_items_options = options
      normalized_items_output = original.call(value, **options)
    end

    expect(Receipts::Processing::ReferencePricingAutoAdoptionFence.serialization_required?(run)).to be(true)

    result = Receipts::Processing.run_finalize(run)

    expect(writer_result).to be_applied
    expect(normalized_items_options).to eq(trusted_reference_pricing_auto_adoption: true)
    expect(normalized_items_input).to contain_exactly(include(pricing_source_kind: 'reference_quantity_price'))
    expect(normalized_items_input.sole.slice(
      :reference_price_amount,
      :reference_quantity,
      :quantity,
      :reference_quantity_unit_code,
      :quantity_unit_code,
      :quantity_unit_raw,
      :reference_quantity_unit_raw,
      :reference_price_tax_inclusion
    )).to eq(
      reference_price_amount: '120',
      reference_quantity: '1',
      quantity: BigDecimal('2.5'),
      reference_quantity_unit_code: 'liter',
      quantity_unit_code: 'liter',
      quantity_unit_raw: nil,
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: 'gross'
    )
    expect(normalized_items_output).to contain_exactly(include(pricing_source_kind: 'reference_quantity_price'))
    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(item).to have_attributes(
        raw_text: '検証品A01',
        suggested_name: '検証品A01',
        confirmed_name: nil,
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('120'),
        reference_quantity: BigDecimal('1'),
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'gross',
        quantity: BigDecimal('2.5'),
        quantity_unit_code: 'liter',
        price: nil,
        original_line_total: 300,
        line_total: 300
      )
      expect(receipt.total_amount).to eq(300)
      expect(run.reload).to have_attributes(status: 'succeeded', stage: 'completed')
      expect(run.final_result_summary).to include('item_count' => 1)
      expect(run.metadata.dig('reference_pricing_auto_adoption_claim', 'proposal_checksum')).to be_present
      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'reference_pricing')).to eq(proposal_before)
    end
  end

  it 'settingが未設定またはfalseならproposal生成を維持しauthorityだけ採用しない' do
    allow(SystemSettings).to receive(:fetch_for_update).and_call_original
    allow(SystemSettings).to receive(:with_dependency_lock).and_call_original

    [ nil, false ].each do |setting_value|
      SystemSetting.delete_all
      create_setting(setting_value) unless setting_value.nil?

      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = build_ready_run(receipt)

      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'reference_pricing')).to be_present
      expect { Receipts::Processing.run_finalize(run) }
        .not_to change { ReceiptItem.where(receipt:).count }

      aggregate_failures do
        expect(run.reload.status).to eq('succeeded')
        expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
        expect(receipt.reload.total_amount).to eq(300)
      end
    end

    expect(SystemSettings).not_to have_received(:fetch_for_update)
    expect(SystemSettings).not_to have_received(:with_dependency_lock)
  end

  it 'A1が有効でもproposalのない通常receiptはFinalize時のdependency lockとsetting row lockを増やさない' do
    create_setting(true)
    plain_ocr_result = {
      success: true,
      lines: [ '合計 300円' ],
      candidates: {
        store_name: '検証店舗',
        total_amount: 300,
        country_region: 'JPN',
        currency_code: 'JPY',
        items: [],
        payments: [],
        tax_details: []
      }
    }
    allow(SystemSettings).to receive(:fetch_for_update).and_call_original
    allow(SystemSettings).to receive(:with_dependency_lock).and_call_original

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, ocr_result: plain_ocr_result)

    expect(Receipts::Processing::ReferencePricingAutoAdoptionFence.serialization_required?(run)).to be(false)
    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.total_amount).to eq(300)
      expect(run.reload.status).to eq('succeeded')
    end

    expect(SystemSettings).not_to have_received(:fetch_for_update)
    expect(SystemSettings).not_to have_received(:with_dependency_lock)
  end

  it 'Amount計算結果にpriceが含まれてもreference sourceのlegacy priceへ昇格しない' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).deep_dup.tap do |result|
        result.dig(:computed, :items).sole[:price] = 999
      end
    end

    Receipts::Processing.run_finalize(run)

    expect(receipt.reload.receipt_items.sole).to have_attributes(
      price: nil,
      reference_price_amount: BigDecimal('120'),
      original_line_total: 300,
      line_total: 300
    )
  end

  it 'trusted normalizerがproposal itemを拒否した場合はauthorityとclaimをatomicにrollbackする' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    allow(Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer).to receive(:items).and_return([])

    expect { Receipts::Processing.run_finalize(run) }.to raise_error(
      Receipts::Processing::AnalysisError,
      'reference_pricing_auto_adoption_persistence_mismatch'
    )

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.status).to eq('failed')
      expect(run.reload.status).to eq('failed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.metadata.dig('stage_execution_claims', 'finalize')).to be_nil
    end
  end

  it 'Amount derived totalがdeterministic projectionとずれた場合はauthorityとclaimを残さない' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).deep_dup.tap do |result|
        result.dig(:computed, :items).sole[:original_line_total] = 301
        result.dig(:computed, :items).sole[:line_total] = 301
      end
    end

    expect { Receipts::Processing.run_finalize(run) }.to raise_error(
      Receipts::Processing::AnalysisError,
      'reference_pricing_auto_adoption_persistence_mismatch'
    )

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.status).to eq('failed')
      expect(run.reload.status).to eq('failed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.metadata.dig('stage_execution_claims', 'finalize')).to be_nil
    end
  end

  it '同じderived totalになる等価なsourceへ正規化されてもexact source driftとしてrollbackする' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    allow(Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer).to receive(:items)
      .and_wrap_original do |original, items, **options|
        original.call(items, **options).tap do |normalized|
          next unless options[:trusted_reference_pricing_auto_adoption] && normalized.one?

          normalized.sole[:reference_price_amount] = BigDecimal('240')
          normalized.sole[:reference_quantity] = BigDecimal('2')
        end
      end

    expect { Receipts::Processing.run_finalize(run) }.to raise_error(
      Receipts::Processing::AnalysisError,
      'reference_pricing_auto_adoption_persistence_mismatch'
    )

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.status).to eq('failed')
      expect(run.reload.status).to eq('failed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'OCR binding後にReceipt versionまたはsetting generationが変わるとstale authorityを書かない' do
    setting = create_setting(true)

    stale_receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    stale_run = build_ready_run(stale_receipt)
    stale_receipt.update!(memo: 'changed after proposal binding')

    generation_receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    generation_run = build_ready_run(generation_receipt)
    setting.update!(value: SystemSettings.stored_value(false))
    setting.update!(value: SystemSettings.stored_value(true))

    Receipts::Processing.run_finalize(stale_run)
    Receipts::Processing.run_finalize(generation_run)

    aggregate_failures do
      expect(stale_receipt.reload.receipt_items).to be_empty
      expect(generation_receipt.reload.receipt_items).to be_empty
      expect(stale_receipt.status).to eq('failed')
      expect(stale_receipt.processing_error_code).to eq('analysis_stale_run')
      expect(stale_run.reload.status).to eq('failed')
      expect(generation_run.reload.status).to eq('succeeded')
      expect(stale_run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(generation_run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'setting rowのreset相当delete・recreate後は同じtrueでもold generationを採用しない' do
    setting = create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    original_generation = run.metadata.dig(
      'reference_pricing_auto_adoption_gate',
      'setting_generation'
    )
    setting.destroy!
    recreated = create_setting(true)

    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(recreated.id).not_to eq(original_generation.fetch('id'))
      expect(result.next_step).to eq(:done)
      expect(receipt.reload.receipt_items).to be_empty
      expect(run.reload.status).to eq('succeeded')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'run開始後かつOCR proposal binding前のReceipt変更も開始時versionで拒否する' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    start_version = run.metadata.dig(
      'reference_pricing_auto_adoption_gate',
      'receipt_lock_version_at_start'
    )
    receipt.update!(memo: 'changed before proposal binding')
    Receipts::Processing.record_ocr_snapshot(run, destination_ocr_result)
    Receipts::Processing.record_finalize_decision(run, finalize_decision)

    result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(start_version).to be < receipt.lock_version
      expect(run.reload.metadata.dig(
        'reference_pricing_auto_adoption_gate',
        'proposal_binding',
        'receipt_lock_version'
      )).to eq(start_version)
      expect(result.next_step).to eq(:skipped)
      expect(result.skip_reason).to eq(:analysis_stale_run)
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.status).to eq('failed')
      expect(run.status).to eq('failed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'proposal binding後に別writerが保存したauthorityをFinalize全体で保持する' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    existing_item = receipt.receipt_items.create!(
      confirmed_name: '先行保存明細',
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 300,
      line_total: 300,
      needs_review: false,
      review_reasons: []
    )
    before = existing_item.attributes.slice(
      'id',
      'confirmed_name',
      'pricing_source_kind',
      'price',
      'quantity',
      'quantity_unit_code',
      'original_line_total',
      'line_total'
    )

    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(result.next_step).to eq(:skipped)
      expect(result.skip_reason).to eq(:analysis_stale_run)
      expect(receipt.reload).to have_attributes(
        status: 'failed',
        processing_error_code: 'analysis_stale_run'
      )
      expect(receipt.receipt_items.count).to eq(1)
      expect(existing_item.reload.attributes.slice(*before.keys)).to eq(before)
      expect(run.reload.status).to eq('failed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'proposal binding後に保存されたadjustment・payment・tax detailも全置換せず保持する' do
    create_setting(true)
    creators = {
      adjustment: ->(receipt) {
        receipt.receipt_adjustments.create!(
          kind: 'delivery_fee',
          label: '先行調整',
          amount: 10,
          sign: 'surcharge',
          source: 'manual',
          needs_review: false,
          review_reasons: []
        )
      },
      payment: ->(receipt) { receipt.receipt_payments.create!(method: 'cash', amount: 300) },
      tax_detail: ->(receipt) {
        receipt.receipt_tax_details.create!(rate: BigDecimal('0.1'), net_amount: 273, amount: 27)
      }
    }

    creators.each do |kind, create_child|
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = build_ready_run(receipt)
      child = create_child.call(receipt)
      before = child.attributes.deep_dup

      result = Receipts::Processing.run_finalize(run)

      aggregate_failures(kind) do
        expect(result.skip_reason).to eq(:analysis_stale_run)
        expect(child.reload.attributes).to eq(before)
        expect(receipt.reload.status).to eq('failed')
        expect(run.reload.status).to eq('failed')
        expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      end
    end
  end

  it 'final summary失敗時はstage claim・authority・A1 claim・run successを一体でrollbackする' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    original_total = receipt.total_amount
    allow(Receipts::Processing).to receive(:record_final_result).and_raise('summary write failed')

    expect { Receipts::Processing.run_finalize(run) }.to raise_error('summary write failed')

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.total_amount).to eq(original_total)
      expect(receipt.status).to eq('failed')
      expect(run.reload.status).to eq('failed')
      expect(run.final_result_summary).to be_blank
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.metadata.dig('stage_execution_claims', 'finalize')).to be_nil
    end
  end

  it 'transient DB競合はrunをterminal化せず全writeをrollbackしてretry可能にする' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    allow(ReceiptAmountService).to receive(:call).and_raise(ActiveRecord::Deadlocked)

    expect { Receipts::Processing.run_finalize(run) }.to raise_error(
      Receipts::Processing::RetryableFinalizeError,
      'transient_finalize_database_error'
    ) { |error| expect(error.cause).to be_a(ActiveRecord::Deadlocked) }

    aggregate_failures do
      expect(receipt.reload.status).to eq('processing')
      expect(receipt.receipt_items).to be_empty
      expect(run.reload).to be_active
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.metadata.dig('stage_execution_claims', 'finalize')).to be_nil
    end
  end

  it 'transient DB競合後のjob retryとduplicate finalizeでもauthority writeは最大1回にする' do
    create_setting(true)

    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt)
    calls = 0
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      calls += 1
      raise ActiveRecord::LockWaitTimeout if calls == 1

      original.call(**kwargs)
    end

    expect { Receipts::Processing.run_finalize(run) }.to raise_error(
      Receipts::Processing::RetryableFinalizeError,
      'transient_finalize_database_error'
    ) { |error| expect(error.cause).to be_a(ActiveRecord::LockWaitTimeout) }
    retry_result = Receipts::Processing.run_finalize(run.reload)
    duplicate_result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(retry_result.next_step).to eq(:done)
      expect(duplicate_result.next_step).to eq(:skipped)
      expect(duplicate_result.skip_reason).to eq(:terminal_run)
      expect(receipt.reload.receipt_items.count).to eq(1)
      expect(receipt.receipt_items.sole.pricing_source_kind).to eq('reference_quantity_price')
      expect(run.reload.status).to eq('succeeded')
      expect(run.metadata).to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'candidate count・identity・validation stateの最終snapshotが変わるとauthorityを採用しない' do
    create_setting(true)

    mutations = [
      proc do |snapshot|
        snapshot.dig('candidate_counts', 'reference_pricing_candidates')['actual_count'] = 2
      end,
      proc do |snapshot|
        snapshot.dig('candidates', 'reference_pricing_candidates', 0)['candidate_id'] =
          'azure_line_group_p0_l8_l9_reference_pricing'
      end,
      proc do |snapshot|
        snapshot.dig('candidates', 'reference_pricing_candidates', 0)['validation_state'] = 'ambiguous'
      end
    ]

    mutations.each do |mutate|
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = build_ready_run(receipt)
      changed = run.ocr_result_snapshot.deep_dup
      mutate.call(changed)
      run.update!(ocr_result_snapshot: changed)

      Receipts::Processing.run_finalize(run)

      aggregate_failures do
        expect(receipt.reload.receipt_items).to be_empty
        expect(run.reload.status).to eq('succeeded')
        expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      end
    end
  end

  it 'destinationが0件・複数相当・identity不一致へ変わるとfinal transactionで採用しない' do
    create_setting(true)

    mutations = [
      proc do |snapshot|
        snapshot.dig('adoption_proposals', 'reference_pricing').delete('destination')
      end,
      proc do |snapshot|
        destination = snapshot.dig('adoption_proposals', 'reference_pricing', 'destination')
        snapshot.dig('adoption_proposals', 'reference_pricing')['destination'] = [ destination, destination ]
      end,
      proc do |snapshot|
        snapshot.dig('adoption_proposals', 'reference_pricing', 'destination')['identity'] =
          'azure_line_group_destination_p0_name_l9_s0_e1_ref_l9_qty_l10'
      end
    ]

    mutations.each do |mutate|
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = build_ready_run(receipt)
      changed = run.ocr_result_snapshot.deep_dup
      mutate.call(changed)
      run.update!(ocr_result_snapshot: changed)

      result = Receipts::Processing.run_finalize(run.reload)

      aggregate_failures do
        expect(result.next_step).to eq(:done)
        expect(receipt.reload.receipt_items).to be_empty
        expect(run.reload.status).to eq('succeeded')
        expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      end
    end
  end

  it 'bound gateが欠損・旧version・型不正でもproposalを維持して通常Finalizeへfail-closedする' do
    create_setting(true)

    mutations = [
      proc { |metadata| metadata.delete('reference_pricing_auto_adoption_gate') },
      proc do |metadata|
        metadata.dig('reference_pricing_auto_adoption_gate')['schema_version'] =
          'reference_pricing_auto_adoption_gate_v1'
      end,
      proc { |metadata| metadata['reference_pricing_auto_adoption_gate'] = [] }
    ]

    mutations.each do |mutate|
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = build_ready_run(receipt)
      proposal_before = run.ocr_result_snapshot.dig('adoption_proposals', 'reference_pricing').deep_dup
      changed_metadata = run.metadata.deep_dup
      mutate.call(changed_metadata)
      run.update!(metadata: changed_metadata)

      result = Receipts::Processing.run_finalize(run.reload)

      aggregate_failures do
        expect(result.next_step).to eq(:done)
        expect(receipt.reload.receipt_items).to be_empty
        expect(run.reload.status).to eq('succeeded')
        expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
        expect(run.ocr_result_snapshot.dig('adoption_proposals', 'reference_pricing')).to eq(proposal_before)
      end
    end
  end
end
