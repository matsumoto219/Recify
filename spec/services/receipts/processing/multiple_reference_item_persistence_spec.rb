require 'rails_helper'

RSpec.describe 'Multiple reference item persistence' do
  def multiple_reference_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    content = analyze_result.fetch('content')
    offset = content.length + 1
    item = analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray').sole.deep_dup
    ([ item ] + item.fetch('valueObject').values).each do |field|
      field.fetch('spans').each { |span| span['offset'] += offset }
    end
    item['content'] = item.fetch('content').sub('検証品', '確認品')
    item.fetch('valueObject').fetch('Description').merge!('content' => '確認品', 'valueString' => '確認品')
    analyze_result['content'] = "#{content}\n#{item.fetch('content')}"
    analyze_result.fetch('pages').sole.fetch('spans').sole['length'] = analyze_result.fetch('content').length
    analyze_result.fetch('documents').sole.fetch('spans').sole['length'] = analyze_result.fetch('content').length
    analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray') << item

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def ready_run(setting_enabled: true)
    create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(setting_enabled)
    )
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, multiple_reference_ocr_result)
    decision = Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: 'ocr_only',
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
    Receipts::Processing.record_finalize_decision(run, decision)
    run.reload
  end

  it '独立したreference明細を全件同じ世代境界へ束縛し単一候補へ偽装しない' do
    run = ready_run
    snapshot = run.ocr_result_snapshot
    gate = run.metadata.fetch('reference_pricing_auto_adoption_gate')

    aggregate_failures do
      expect(snapshot.dig('adoption_proposals', 'item_calculation_modes').size).to eq(2)
      expect(snapshot.dig('candidates', 'reference_pricing_candidates').size).to eq(2)
      expect(gate.fetch('proposal_binding')).to include(
        'binding_kind' => 'azure_item_reference_set',
        'item_count' => 2,
        'proposal_checksum' => match(/\A[0-9a-f]{64}\z/)
      )
      expect(gate.to_json.bytesize).to be <= Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::MAX_SERIALIZED_BYTES
      expect(gate.to_json).not_to include('検証品', '確認品', 'reference_price_amount')
    end
  end

  it '複数referenceの全件を保存し再Finalizeでもsourceと金額を変更しない' do
    run = ready_run
    first_result = Receipts::Processing.run_finalize(run)
    receipt = run.receipt.reload
    sources = receipt.receipt_items.order(:position_index).pluck(
      :id,
      :pricing_source_kind,
      :reference_price_amount,
      :reference_quantity,
      :reference_quantity_unit_code,
      :quantity,
      :quantity_unit_code,
      :line_total
    )
    second_result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(first_result.next_step).to eq(:done)
      expect(second_result.next_step).to eq(:skipped)
      expect(sources.size).to eq(2)
      expect(sources.map { |source| source.drop(1) }).to all(eq([
        'reference_quantity_price',
        BigDecimal('498'),
        BigDecimal('100'),
        'gram',
        BigDecimal('342'),
        'gram',
        1703
      ]))
      expect(receipt.reload.total_amount).to eq(3406)
      expect(receipt.receipt_items.order(:position_index).pluck(
        :id,
        :pricing_source_kind,
        :reference_price_amount,
        :reference_quantity,
        :reference_quantity_unit_code,
        :quantity,
        :quantity_unit_code,
        :line_total
      )).to eq(sources)
    end
  end

  it '開始時OFFまたは世代が変わったrunでは複数referenceも自動採用しない' do
    [ false, true ].each do |enabled|
      run = ready_run(setting_enabled: enabled)
      setting = SystemSetting.find_by!(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY)
      setting.update!(value: SystemSettings.stored_value(!enabled))
      setting.update!(value: SystemSettings.stored_value(true)) if enabled

      result = Receipts::Processing.run_finalize(run)

      aggregate_failures do
        expect(result.next_step).to eq(:done)
        expect(run.receipt.reload.receipt_items.pluck(:pricing_source_kind)).not_to include('reference_quantity_price')
      end
      setting.destroy!
    end
  end

  it '一方のproposalだけ改変されても全体bindingを再利用しない' do
    run = ready_run
    snapshot = run.ocr_result_snapshot.deep_dup
    proposal = snapshot.fetch('adoption_proposals').fetch('item_calculation_modes').last
    option = proposal.fetch('options').find { |entry| entry['pricing_source_kind'] == 'reference_quantity_price' }
    option.fetch('source')['reference_price_amount'] = '499'
    run.update!(ocr_result_snapshot: snapshot)

    Receipts::Processing.run_finalize(run.reload)

    expect(run.receipt.reload.receipt_items.pluck(:pricing_source_kind)).not_to include('reference_quantity_price')
  end

  it 'binding後にreceipt versionと明細が変更された場合はsourceを上書きしない' do
    run = ready_run
    item = run.receipt.receipt_items.create!(
      confirmed_name: '確認明細',
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      quantity: 1,
      line_total: 250,
      original_line_total: 250
    )
    run.receipt.update!(memo: '確認済み')
    before = item.attributes

    Receipts::Processing.run_finalize(run.reload)

    expect(item.reload.attributes).to eq(before)
    expect(run.receipt.receipt_items.pluck(:id)).to eq([ item.id ])
  end

  it 'unknown fieldと範囲外件数のbatch bindingを拒否する' do
    run = ready_run
    original = run.metadata.fetch('reference_pricing_auto_adoption_gate')
    contract = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot
    mutations = [
      ->(binding) { binding['item_count'] = 1 },
      ->(binding) { binding['item_count'] = 101 },
      ->(binding) { binding['item_count'] = '2' },
      ->(binding) { binding['proposal_checksum'] = 'invalid' },
      ->(binding) { binding['unexpected'] = true }
    ]

    mutations.each do |mutation|
      snapshot = original.deep_dup
      mutation.call(snapshot.fetch('proposal_binding'))

      expect(contract.from_snapshot(snapshot)).to be_nil
    end
  end

  it '旧gate versionに複数referenceの意味を追加しない' do
    run = ready_run
    contract = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot

    [ contract::LEGACY_SCHEMA_VERSION, contract::PREVIOUS_SCHEMA_VERSION ].each do |version|
      binding = contract.proposal_binding_for(
        ocr_snapshot: run.ocr_result_snapshot,
        receipt_lock_version: 0,
        schema_version: version
      )

      expect(binding).to be_nil
    end
  end
end
