require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot do
  def receipt_with_image
    create(:receipt, :with_image)
  end

  def analysis_run
    create(:receipt_analysis_run, receipt: receipt_with_image)
  end

  def destination_ocr_snapshot
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  def structured_reference_ocr_snapshot
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  def structured_layout_reference_ocr_snapshot
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_summary_gross_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  def shared_basis_external_tax_ocr_snapshot
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_summary_net_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  def bound_gate_for(receipt, ocr_snapshot: destination_ocr_snapshot)
    run = create(:receipt_analysis_run, receipt:)
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt:
    )
    bound = described_class.bind(start_snapshot, run:, ocr_snapshot:)

    [ run, bound ]
  end

  def stub_shared_basis_external_tax_net_batch(ocr_snapshot, **decision_overrides)
    proposal = ocr_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole.deep_dup
    reference = proposal.fetch('options').find do |option|
      option.fetch('pricing_source_kind') == 'reference_quantity_price'
    end
    reference.dig('source')['reference_price_tax_inclusion'] = 'net'
    reference.dig('evidence')['tax_inclusion'] = {
      'kind' => 'shared_basis_external_tax_summary'
    }
    decision_attributes = {
      state: 'confirmed',
      reason: 'formula_matches_printed_total',
      candidate_id: proposal.fetch('candidate_id'),
      item_identity: proposal.fetch('item_identity'),
      selected_proposal_id: reference.fetch('proposal_id'),
      selected_pricing_source_kind: 'reference_quantity_price',
      projected_line_total: 1703,
      option_proposal_ids: proposal.fetch('options').pluck('proposal_id')
    }.merge(decision_overrides)
    decision = Receipts::Processing::Contracts::ItemCalculationModeDecision::Result.new(**decision_attributes)
    batch = Receipts::Processing::Contracts::ItemCalculationModeDecision::BatchResult.new(
      proposals: [ proposal ],
      decisions: [ decision ]
    )
    allow(Receipts::Processing::Contracts::ItemCalculationModeProposalSet).to receive(
      :from_snapshot
    ).and_return([ proposal ])
    allow(Receipts::Processing::Contracts::ItemCalculationModeDecision).to receive(
      :evaluate_all
    ).and_return(batch)

    [ proposal, reference ]
  end

  it 'run開始時のsetting state・generation・Receipt/image stateをbounded v4 snapshotへ固定する' do
    setting = create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    run_key = SecureRandom.uuid
    receipt = receipt_with_image

    snapshot = described_class.capture_start(
      run_key:,
      run_source: 'upload',
      receipt:
    )

    aggregate_failures do
      expect(snapshot).to include(
        'schema_version' => 'reference_pricing_auto_adoption_gate_v4',
        'capture_stage' => 'run_start',
        'setting_key' => SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
        'setting_enabled' => true,
        'eligibility_contract_version' => 'reference_pricing_auto_adoption_eligibility_v1',
        'writer_contract_version' => 'reference_pricing_auto_adoption_writer_v3',
        'run_key' => run_key,
        'run_source' => 'upload',
        'proposal_binding' => nil
      )
      expect(snapshot.fetch('receipt_state_at_start')).to include(
        'lock_version' => receipt.lock_version,
        'image_attachment_id' => receipt.image.attachment.id,
        'image_blob_id' => receipt.image.blob.id,
        'image_analyzed' => false,
        'semantic_checksum' => match(/\A[0-9a-f]{64}\z/)
      )
      expect(snapshot.fetch('setting_generation')).to eq(
        'kind' => 'row',
        'id' => setting.id,
        'lock_version' => setting.lock_version
      )
      expect(JSON.generate(snapshot).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
      expect(snapshot.to_json).not_to include(
        receipt.store_name,
        receipt.image.filename.to_s,
        'identified',
        'metadata'
      )
    end
  end

  it 'setting rowなしはfalseと専用absent sentinelで固定する' do
    snapshot = described_class.capture_start(
      run_key: SecureRandom.uuid,
      run_source: 'batch_upload',
      receipt: receipt_with_image
    )

    aggregate_failures do
      expect(snapshot['setting_enabled']).to be(false)
      expect(snapshot['setting_generation']).to eq('kind' => 'absent')
    end
  end

  it '同じ画像世代と未解析から解析済みへの単一遷移だけを有効なReceipt stateにする' do
    receipt = receipt_with_image
    _run, bound = bound_gate_for(receipt)
    start_lock_version = receipt.lock_version

    stable_version = described_class.validated_receipt_lock_version(bound, receipt:)
    ActiveStorage::AnalyzeJob.perform_now(receipt.image.blob)
    receipt.reload
    analyzed_version = described_class.validated_receipt_lock_version(bound, receipt:)

    aggregate_failures do
      expect(stable_version).to eq(start_lock_version)
      expect(receipt.lock_version).to eq(start_lock_version + 1)
      expect(receipt.image.blob.reload).to be_analyzed
      expect(analyzed_version).to eq(receipt.lock_version)
    end
  end

  it 'run開始前に画像解析済みならstable stateとして有効にする' do
    receipt = receipt_with_image
    ActiveStorage::AnalyzeJob.perform_now(receipt.image.blob)
    receipt.reload
    _run, bound = bound_gate_for(receipt)

    aggregate_failures do
      expect(receipt.image.blob.reload).to be_analyzed
      expect(described_class.validated_receipt_lock_version(bound, receipt:)).to eq(receipt.lock_version)
    end
  end

  it '画像解析ではない単一touch・semantic edit・解析後の追加touchを拒否する' do
    cases = {
      receipt_touch: ->(receipt) { receipt.touch },
      semantic_edit: ->(receipt) { receipt.update!(memo: 'changed after run start') },
      analyze_then_touch: ->(receipt) {
        ActiveStorage::AnalyzeJob.perform_now(receipt.image.blob)
        receipt.reload.touch
      }
    }

    cases.each do |name, mutate|
      receipt = receipt_with_image
      _run, bound = bound_gate_for(receipt)
      mutate.call(receipt)

      expect(
        described_class.validated_receipt_lock_version(bound, receipt: receipt.reload)
      ).to be_nil, name.to_s
    end
  end

  it 'Receipt touchを伴わないblob analyzed state改変もfail-closedにする' do
    receipt = receipt_with_image
    _run, bound = bound_gate_for(receipt)
    start_lock_version = receipt.lock_version

    receipt.image.blob.update_columns(
      metadata: receipt.image.blob.metadata.merge('analyzed' => true)
    )

    aggregate_failures do
      expect(receipt.reload.lock_version).to eq(start_lock_version)
      expect(receipt.image.blob.reload).to be_analyzed
      expect(described_class.validated_receipt_lock_version(bound, receipt:)).to be_nil
    end
  end

  it '同じblobの画像解析が重複してReceiptを2回touchした場合は拒否する' do
    receipt = receipt_with_image
    _run, bound = bound_gate_for(receipt)
    start_lock_version = receipt.lock_version

    2.times { ActiveStorage::AnalyzeJob.perform_now(receipt.image.blob.reload) }
    receipt.reload

    aggregate_failures do
      expect(receipt.lock_version).to eq(start_lock_version + 2)
      expect(receipt.image.blob.reload).to be_analyzed
      expect(described_class.validated_receipt_lock_version(bound, receipt:)).to be_nil
    end
  end

  it 'run開始後に画像attachmentまたはblob identityが変わると拒否する' do
    receipt = receipt_with_image
    _run, bound = bound_gate_for(receipt)
    original_attachment_id = receipt.image.attachment.id
    original_blob_id = receipt.image.blob.id

    receipt.image.attach(
      io: File.open(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
      filename: 'replacement_receipt.jpg',
      content_type: 'image/jpeg'
    )
    receipt.reload

    aggregate_failures do
      expect(receipt.image.attachment.id).not_to eq(original_attachment_id)
      expect(receipt.image.blob.id).not_to eq(original_blob_id)
      expect(described_class.validated_receipt_lock_version(bound, receipt:)).to be_nil
    end
  end

  it '同じblobをdetach後にre-attachしたattachment ABAも拒否する' do
    receipt = receipt_with_image
    _run, bound = bound_gate_for(receipt)
    original_attachment_id = receipt.image.attachment.id
    original_blob = receipt.image.blob

    receipt.image.detach
    receipt.image.attach(original_blob)
    receipt.reload

    aggregate_failures do
      expect(receipt.image.attachment.id).not_to eq(original_attachment_id)
      expect(receipt.image.blob.id).to eq(original_blob.id)
      expect(described_class.validated_receipt_lock_version(bound, receipt:)).to be_nil
    end
  end

  it 'automatic adoption対象外のrun sourceにはgate metadataを作らない' do
    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'admin_retry',
        receipt: receipt_with_image
      )
    ).to be_nil
  end

  it 'semantic Receipt payloadが上限を超える場合はdigestの部分保存をせずgateを作らない' do
    receipt = receipt_with_image
    receipt.update_columns(memo: 'x' * (described_class::MAX_SEMANTIC_RECEIPT_BYTES + 1))

    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'upload',
        receipt:
      )
    ).to be_nil
  end

  it 'OCR proposal生成時に同じrunへidentity/checksumと開始時Receipt versionだけをbindする' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    ocr_snapshot = destination_ocr_snapshot
    proposal = ocr_snapshot.dig('adoption_proposals', 'reference_pricing')

    bound = described_class.bind(
      start_snapshot,
      run:,
      ocr_snapshot:
    )

    aggregate_failures do
      expect(bound.fetch('proposal_binding')).to eq(
        'binding_kind' => 'azure_line_group',
        'candidate_identity' => proposal.fetch('candidate_id'),
        'destination_identity' => proposal.dig('destination', 'identity'),
        'proposal_checksum' => proposal.fetch('integrity_checksum'),
        'receipt_lock_version' => run.receipt.lock_version
      )
      expect(bound['setting_enabled']).to be(false)
      expect(bound.to_json).not_to include(
        '検証品A01',
        'SYNTH-LAYOUT',
        'reference_price_amount',
        'case_preserved_lines',
        'polygon',
        '/private/'
      )
    end
  end

  it 'confirmedなstructured Itemのreference optionをline-groupへ偽装せずbindする' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    ocr_snapshot = structured_reference_ocr_snapshot
    proposal = ocr_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole

    bound = described_class.bind(start_snapshot, run:, ocr_snapshot:)

    aggregate_failures do
      expect(bound.fetch('proposal_binding')).to eq(
        'binding_kind' => 'azure_structured_item_reference',
        'candidate_identity' => proposal.fetch('candidate_id'),
        'destination_identity' => proposal.fetch('item_identity'),
        'selected_proposal_identity' => 'azure_items_0_reference_quantity_price',
        'decision_contract_version' => 'item_calculation_mode_decision_v1',
        'proposal_checksum' => proposal.fetch('integrity_checksum'),
        'receipt_lock_version' => run.receipt.lock_version
      )
      expect(bound.to_json).not_to include(
        '検証品',
        'reference_price_amount',
        'polygon'
      )
    end
  end

  it 'layout sourceとstructured destinationのreference optionをexact identity pairでbindする' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    ocr_snapshot = structured_layout_reference_ocr_snapshot
    proposal = ocr_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole
    reference_option = proposal.fetch('options').find do |option|
      option['pricing_source_kind'] == 'reference_quantity_price'
    end

    bound = described_class.bind(start_snapshot, run:, ocr_snapshot:)

    aggregate_failures do
      expect(bound.fetch('proposal_binding')).to eq(
        'binding_kind' => 'azure_structured_item_reference',
        'candidate_identity' => proposal.fetch('candidate_id'),
        'destination_identity' => proposal.fetch('item_identity'),
        'selected_proposal_identity' => reference_option.fetch('proposal_id'),
        'decision_contract_version' => 'item_calculation_mode_decision_v1',
        'proposal_checksum' => proposal.fetch('integrity_checksum'),
        'receipt_lock_version' => run.receipt.lock_version
      )
      expect(proposal.fetch('candidate_id')).to start_with('azure_item_layout_')
      expect(proposal.fetch('item_identity')).to start_with('azure_structured_item_')
      redacted_bound = bound.deep_dup
      redacted_bound.dig('proposal_binding')['proposal_checksum'] = '[CHECKSUM]'
      redacted_bound.dig('receipt_state_at_start')['semantic_checksum'] = '[CHECKSUM]'
      expect(redacted_bound.to_json).not_to include(
        '例示量売品A',
        'reference_price_amount',
        '498',
        '342',
        'polygon'
      )
    end
  end

  it 'validated shared external-tax net decisionをstructured destinationへbindする' do
    ocr_snapshot = shared_basis_external_tax_ocr_snapshot
    proposal = ocr_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole
    reference = proposal.fetch('options').find do |option|
      option.fetch('pricing_source_kind') == 'reference_quantity_price'
    end

    binding = described_class.proposal_binding_for(
      ocr_snapshot:,
      receipt_lock_version: 0
    )

    expect(binding).to eq(
      'binding_kind' => 'azure_structured_item_reference',
      'candidate_identity' => proposal.fetch('candidate_id'),
      'destination_identity' => proposal.fetch('item_identity'),
      'selected_proposal_identity' => reference.fetch('proposal_id'),
      'decision_contract_version' => 'item_calculation_mode_decision_v1',
      'proposal_checksum' => proposal.fetch('integrity_checksum'),
      'receipt_lock_version' => 0
    )
  end

  it 'generic net evidenceはconfirmed decisionでもstructured bindingへ通さない' do
    ocr_snapshot = structured_reference_ocr_snapshot
    _proposal, reference = stub_shared_basis_external_tax_net_batch(ocr_snapshot)
    reference.dig('evidence')['tax_inclusion'] = {
      'source_field_path' => 'documents[0].fields.Items[0].Price',
      'provider_span_start' => 4,
      'provider_span_end' => 6
    }

    expect(
      described_class.proposal_binding_for(ocr_snapshot:, receipt_lock_version: 0)
    ).to be_nil
  end

  it 'shared net decisionのcandidate・destination・proposal identity不一致をbindしない' do
    cases = {
      candidate: { candidate_id: 'azure_items_1_item_calculation_mode' },
      destination: { item_identity: 'azure_structured_item_i1_s0_e28' },
      proposal: { selected_proposal_id: 'azure_items_1_reference_quantity_price' }
    }

    cases.each do |name, overrides|
      ocr_snapshot = structured_reference_ocr_snapshot
      stub_shared_basis_external_tax_net_batch(ocr_snapshot, **overrides)

      expect(
        described_class.proposal_binding_for(ocr_snapshot:, receipt_lock_version: 0)
      ).to be_nil, name.to_s
    end
  end

  it '改変されたstructured proposal checksumをbindしない' do
    ocr_snapshot = structured_reference_ocr_snapshot
    ocr_snapshot.dig(
      'adoption_proposals',
      'item_calculation_modes',
      0
    )['integrity_checksum'] = '0' * 64

    expect(
      described_class.proposal_binding_for(ocr_snapshot:, receipt_lock_version: 0)
    ).to be_nil
  end

  it 'structured bindingのcandidateとselected proposalが同じprovider prefixでなければ拒否する' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    structured_bound = described_class.bind(
      start_snapshot,
      run:,
      ocr_snapshot: structured_reference_ocr_snapshot
    )
    layout_bound = described_class.bind(
      start_snapshot,
      run:,
      ocr_snapshot: structured_layout_reference_ocr_snapshot
    )

    mutations = [
      structured_bound.deep_merge(
        'proposal_binding' => {
          'selected_proposal_identity' => 'azure_items_1_reference_quantity_price'
        }
      ),
      layout_bound.deep_merge(
        'proposal_binding' => {
          'selected_proposal_identity' =>
            'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l5_reference_quantity_price'
        }
      ),
      layout_bound.deep_merge(
        'proposal_binding' => {
          'candidate_identity' =>
            'azure_item_layout_p1_name_l1_ref_l2_qty_l3_total_l4_item_calculation_mode'
        }
      )
    ]

    mutations.each do |mutation|
      expect(described_class.from_snapshot(mutation, run:, require_binding: true)).to be_nil
    end
  end

  it '既存v3 structured gateはprevious contractのまま読み戻す' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    bound = described_class.bind(start_snapshot, run:, ocr_snapshot: structured_reference_ocr_snapshot)
    previous = bound.deep_dup
    previous['schema_version'] = 'reference_pricing_auto_adoption_gate_v3'
    previous['writer_contract_version'] = 'reference_pricing_auto_adoption_writer_v2'
    previous['receipt_lock_version_at_start'] = previous.delete('receipt_state_at_start').fetch('lock_version')
    previous['proposal_binding']['receipt_lock_version'] = run.receipt.lock_version

    aggregate_failures do
      expect(described_class.from_snapshot(previous, run:, require_binding: true)).to eq(previous)
      expect(described_class.validated_receipt_lock_version(previous, receipt: run.receipt)).to eq(
        run.receipt.lock_version
      )
    end

    ActiveStorage::AnalyzeJob.perform_now(run.receipt.image.blob)

    expect(
      described_class.validated_receipt_lock_version(previous, receipt: run.receipt.reload)
    ).to be_nil
  end

  it '既存v3 line-group gateもexact lock contractのまま読み戻す' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    bound = described_class.bind(start_snapshot, run:, ocr_snapshot: destination_ocr_snapshot)
    previous = bound.deep_dup
    previous['schema_version'] = 'reference_pricing_auto_adoption_gate_v3'
    previous['writer_contract_version'] = 'reference_pricing_auto_adoption_writer_v2'
    previous['receipt_lock_version_at_start'] = previous.delete('receipt_state_at_start').fetch('lock_version')
    previous['proposal_binding']['receipt_lock_version'] = run.receipt.lock_version

    aggregate_failures do
      expect(described_class.from_snapshot(previous, run:, require_binding: true)).to eq(previous)
      expect(described_class.validated_receipt_lock_version(previous, receipt: run.receipt)).to eq(
        run.receipt.lock_version
      )
    end

    ActiveStorage::AnalyzeJob.perform_now(run.receipt.image.blob)

    expect(
      described_class.validated_receipt_lock_version(previous, receipt: run.receipt.reload)
    ).to be_nil
  end

  it '既存v2 line-group gateはlegacy contractのまま読み戻す' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    bound = described_class.bind(start_snapshot, run:, ocr_snapshot: destination_ocr_snapshot)
    legacy = bound.deep_dup
    legacy['schema_version'] = 'reference_pricing_auto_adoption_gate_v2'
    legacy['writer_contract_version'] = 'reference_pricing_auto_adoption_writer_v1'
    legacy['receipt_lock_version_at_start'] = legacy.delete('receipt_state_at_start').fetch('lock_version')
    legacy['proposal_binding']['receipt_lock_version'] = run.receipt.lock_version
    legacy['proposal_binding'].delete('binding_kind')

    expect(described_class.from_snapshot(legacy, run:, require_binding: true)).to eq(legacy)
  end

  it 'unknown version・型違い・過大値・run不一致・proposal改変をfail-closedにする' do
    run = analysis_run
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt: run.receipt
    )
    ocr_snapshot = destination_ocr_snapshot
    bound = described_class.bind(
      start_snapshot,
      run:,
      ocr_snapshot:
    )
    mutations = [
      bound.merge('schema_version' => 'reference_pricing_auto_adoption_gate_v1'),
      bound.merge('schema_version' => 'reference_pricing_auto_adoption_gate_v5'),
      bound.merge('unknown' => true),
      bound.merge('setting_enabled' => 'true'),
      bound.deep_merge('setting_generation' => { 'id' => -1 }),
      bound.deep_merge('receipt_state_at_start' => { 'lock_version' => -1 }),
      bound.deep_merge('receipt_state_at_start' => { 'semantic_checksum' => 'x' * 64 }),
      bound.deep_merge('receipt_state_at_start' => { 'image_analyzed' => 'true' }),
      bound.deep_merge('receipt_state_at_start' => { 'image_attachment_id' => -1 }),
      bound.deep_merge('receipt_state_at_start' => { 'image_blob_id' => -1 }),
      bound.merge('run_key' => 'x' * 200)
    ]

    mutations.each do |mutation|
      expect(described_class.from_snapshot(mutation, run:, require_binding: true)).to be_nil
    end


    checksum_tampered = bound.deep_merge('proposal_binding' => { 'proposal_checksum' => '0' * 64 })
    expect(
      described_class.bind(
        checksum_tampered,
        run:,
        ocr_snapshot:
      )
    ).to be_nil

    other_run = create(:receipt_analysis_run, receipt: create(:receipt))
    expect(described_class.from_snapshot(bound, run: other_run, require_binding: true)).to be_nil

    tampered_ocr = ocr_snapshot.deep_dup
    tampered_ocr.dig('adoption_proposals', 'reference_pricing')['integrity_checksum'] = '0' * 64
    expect(
      described_class.bind(
        start_snapshot,
        run:,
        ocr_snapshot: tampered_ocr
      )
    ).to be_nil
  end

  it 'setting取得失敗時はsnapshotを作らずadoptionだけを停止する' do
    receipt = receipt_with_image
    receipt_without_image = create(:receipt)
    allow(SystemSettings).to receive(:fetch).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'upload',
        receipt:
      )
    ).to be_nil
    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'upload',
        receipt: receipt_without_image
      )
    ).to be_nil
  end
end
