require 'rails_helper'

RSpec.describe Receipts::Processing::ReferencePricingAutoAdoptionWriter do
  def destination_snapshot
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  def build_run(receipt)
    create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    run = create(:receipt_analysis_run, receipt:)
    start_gate = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt:
    )
    snapshot = destination_snapshot
    bound_gate = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot.bind(
      start_gate,
      run:,
      ocr_snapshot: snapshot
    )
    run.update!(
      ocr_result_snapshot: snapshot,
      metadata: run.metadata.merge(
        Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::METADATA_KEY => bound_gate
      )
    )
    run
  end

  def eligible_params
    {
      receipt_attributes: {
        country_region: 'JPN',
        currency_code: 'JPY',
        total_amount: 300
      },
      receipt_items_attributes: [],
      receipt_adjustments_attributes: [],
      receipt_payments_attributes: [],
      receipt_tax_details_attributes: []
    }
  end

  def enabled_gate
    Receipts::Processing::ReferencePricingAutoAdoptionFence::Result.new(
      enabled: true,
      reason: 'enabled',
      candidate_identity: 'azure_line_group_p0_l1_l2_reference_pricing',
      destination_identity: 'azure_line_group_destination_p0_name_l1_s13_e19_ref_l1_qty_l2'
    )
  end

  def counted_application_queries
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name].in?(%w[SCHEMA CACHE])
      next if payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    queries
  end

  it 'final lock versionとidentityが一致するstrict gross proposalだけをsource paramsへ追加する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN', currency_code: 'JPY')
    run = build_run(receipt)
    original = eligible_params.deep_dup

    result = nil
    queries = counted_application_queries do
      result = described_class.call(
        receipt:,
        run:,
        params: original,
        gate_result: enabled_gate,
        existing_items: []
      )
    end

    aggregate_failures do
      expect(result).to be_applied
      expect(result.reason).to eq('applied')
      expect(result.params[:receipt_items_attributes].sole).to include(
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: '120',
        reference_quantity: '1',
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'gross',
        quantity: '2.5',
        quantity_unit_code: 'liter',
        price: nil,
        original_line_total: nil,
        line_total: nil
      )
      expect(original[:receipt_items_attributes]).to be_empty
      expect(queries.length).to eq(1)
      expect(queries.sole).to include('"system_settings"')
      expect(queries.join).not_to include('"receipt_items"')
    end
  end

  it 'existing item・BuildParams item・receipt adjustment・profile不一致はauthorityを追加しない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN', currency_code: 'JPY')
    run = build_run(receipt)
    existing_item = ReceiptItem.new(receipt:, raw_text: '既存明細', line_total: 300)

    cases = [
      { existing_items: [ existing_item ] },
      { params: eligible_params.deep_merge(receipt_items_attributes: [ { raw_text: '既存候補' } ]) },
      { params: eligible_params.deep_merge(receipt_adjustments_attributes: [ { amount: 1 } ]) },
      { params: eligible_params.deep_merge(receipt_attributes: { total_amount: 301 }) },
      { params: eligible_params.deep_merge(receipt_attributes: { country_region: 'USA' }) },
      { params: eligible_params.deep_merge(receipt_attributes: { currency_code: 'USD' }) }
    ]

    cases.each do |overrides|
      result = described_class.call(
        receipt:,
        run:,
        params: overrides.fetch(:params, eligible_params),
        gate_result: enabled_gate,
        existing_items: overrides.fetch(:existing_items, [])
      )

      aggregate_failures do
        expect(result).not_to be_applied
        expect(result.params[:receipt_items_attributes]).to eq(
          overrides.fetch(:params, eligible_params)[:receipt_items_attributes]
        )
      end
    end
  end

  it 'persisted Receiptのcurrencyが非JPYならOCR値だけでprofileを上書きしない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN', currency_code: 'USD')
    run = build_run(receipt)

    result = described_class.call(
      receipt:,
      run:,
      params: eligible_params,
      gate_result: enabled_gate,
      existing_items: []
    )

    aggregate_failures do
      expect(result).not_to be_applied
      expect(result.reason).to eq('profile_unsupported')
      expect(result.params[:receipt_items_attributes]).to be_empty
      expect(receipt.reload.currency_code).to eq('USD')
    end
  end

  it 'gate無効・stale Receipt・proposal改変ではpartial sourceを作らない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN', currency_code: 'JPY')
    run = build_run(receipt)
    disabled = Receipts::Processing::ReferencePricingAutoAdoptionFence::Result.new(
      enabled: false,
      reason: 'current_setting_disabled'
    )

    receipt.update!(memo: 'version change')
    stale = described_class.call(
      receipt:,
      run:,
      params: eligible_params,
      gate_result: enabled_gate,
      existing_items: []
    )
    disabled_result = described_class.call(
      receipt:,
      run:,
      params: eligible_params,
      gate_result: disabled,
      existing_items: []
    )

    tampered = run.ocr_result_snapshot.deep_dup
    tampered.dig('adoption_proposals', 'reference_pricing')['reference_price']['amount'] = '999'
    run.update!(ocr_result_snapshot: tampered)
    tampered_result = described_class.call(
      receipt:,
      run:,
      params: eligible_params,
      gate_result: enabled_gate,
      existing_items: []
    )

    aggregate_failures do
      expect(stale.reason).to eq('ineligible')
      expect(disabled_result.reason).to eq('gate_disabled')
      expect(tampered_result.reason).to eq('destination_invalid')
      expect([ stale, disabled_result, tampered_result ]).to all(
        satisfy { |result| !result.applied? && result.params[:receipt_items_attributes].empty? }
      )
    end
  end

  it 'valid proposalと同居する深いunknown siblingを再帰変換せずbounded proposalだけを採用する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN', currency_code: 'JPY')
    run = build_run(receipt)
    deep_value = { 'leaf' => true }
    2_048.times { deep_value = { 'nested' => deep_value } }
    snapshot = run.ocr_result_snapshot.dup
    snapshot['adoption_proposals'] = snapshot.fetch('adoption_proposals').dup
    snapshot['adoption_proposals']['unknown_additive_contract'] = deep_value
    run_with_deep_snapshot = instance_double(
      ReceiptAnalysisRun,
      ocr_result_snapshot: snapshot,
      metadata: run.metadata,
      run_key: run.run_key,
      source: run.source
    )

    result = nil
    expect do
      result = described_class.call(
        receipt:,
        run: run_with_deep_snapshot,
        params: eligible_params,
        gate_result: enabled_gate,
        existing_items: []
      )
    end.not_to raise_error

    expect(result).to be_applied
  end


  it 'printed・explicit・count・reference・partial・manual相当の既存itemを一切上書きしない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN', currency_code: 'JPY')
    run = build_run(receipt)
    existing_authorities = [
      ReceiptItem.new(receipt:, raw_text: 'printed', line_total: 300),
      ReceiptItem.new(
        receipt:,
        raw_text: 'explicit',
        pricing_source_kind: 'explicit_line_total',
        line_total: 300
      ),
      ReceiptItem.new(
        receipt:,
        raw_text: 'count',
        pricing_source_kind: 'count_unit_price',
        price: 100,
        quantity: 3,
        quantity_unit_code: 'each'
      ),
      ReceiptItem.new(
        receipt:,
        raw_text: 'reference',
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: '120',
        reference_quantity: '1',
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'gross',
        quantity: '2.5',
        quantity_unit_code: 'liter'
      ),
      ReceiptItem.new(receipt:, raw_text: 'partial', reference_price_amount: '120'),
      ReceiptItem.new(receipt:, raw_text: 'manual', confirmed_name: 'user edited')
    ]

    existing_authorities.each do |existing_item|
      before = existing_item.attributes.deep_dup
      result = described_class.call(
        receipt:,
        run:,
        params: eligible_params,
        gate_result: enabled_gate,
        existing_items: [ existing_item ]
      )

      aggregate_failures(existing_item.raw_text) do
        expect(result).not_to be_applied
        expect(result.params[:receipt_items_attributes]).to be_empty
        expect(existing_item.attributes).to eq(before)
      end
    end
  end
end
