require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot do
  def destination_ocr_snapshot
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  it 'run開始時のsetting state・generation・Receipt versionをbounded v2 snapshotへ固定する' do
    setting = create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    run_key = SecureRandom.uuid

    snapshot = described_class.capture_start(
      run_key:,
      run_source: 'upload',
      receipt_lock_version: 7
    )

    aggregate_failures do
      expect(snapshot).to include(
        'schema_version' => 'reference_pricing_auto_adoption_gate_v2',
        'capture_stage' => 'run_start',
        'setting_key' => SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
        'setting_enabled' => true,
        'eligibility_contract_version' => 'reference_pricing_auto_adoption_eligibility_v1',
        'writer_contract_version' => 'reference_pricing_auto_adoption_writer_v1',
        'run_key' => run_key,
        'run_source' => 'upload',
        'receipt_lock_version_at_start' => 7,
        'proposal_binding' => nil
      )
      expect(snapshot.fetch('setting_generation')).to eq(
        'kind' => 'row',
        'id' => setting.id,
        'lock_version' => setting.lock_version
      )
      expect(JSON.generate(snapshot).bytesize).to be <= 1024
    end
  end

  it 'setting rowなしはfalseと専用absent sentinelで固定する' do
    snapshot = described_class.capture_start(
      run_key: SecureRandom.uuid,
      run_source: 'batch_upload',
      receipt_lock_version: 0
    )

    aggregate_failures do
      expect(snapshot['setting_enabled']).to be(false)
      expect(snapshot['setting_generation']).to eq('kind' => 'absent')
    end
  end

  it 'automatic adoption対象外のrun sourceにはgate metadataを作らない' do
    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'admin_retry',
        receipt_lock_version: 0
      )
    ).to be_nil
  end

  it 'OCR proposal生成時に同じrunへidentity/checksumと開始時Receipt versionだけをbindする' do
    run = create(:receipt_analysis_run)
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt_lock_version: run.receipt.lock_version
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

  it 'unknown version・型違い・過大値・run不一致・proposal改変をfail-closedにする' do
    run = create(:receipt_analysis_run)
    start_snapshot = described_class.capture_start(
      run_key: run.run_key,
      run_source: run.source,
      receipt_lock_version: run.receipt.lock_version
    )
    ocr_snapshot = destination_ocr_snapshot
    bound = described_class.bind(
      start_snapshot,
      run:,
      ocr_snapshot:
    )
    mutations = [
      bound.merge('schema_version' => 'reference_pricing_auto_adoption_gate_v1'),
      bound.merge('schema_version' => 'reference_pricing_auto_adoption_gate_v3'),
      bound.merge('unknown' => true),
      bound.merge('setting_enabled' => 'true'),
      bound.deep_merge('setting_generation' => { 'id' => -1 }),
      bound.merge('receipt_lock_version_at_start' => -1),
      bound.deep_merge('proposal_binding' => { 'receipt_lock_version' => run.receipt.lock_version + 1 }),
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
    allow(SystemSettings).to receive(:fetch).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'upload',
        receipt_lock_version: 0
      )
    ).to be_nil
    expect(
      described_class.capture_start(
        run_key: SecureRandom.uuid,
        run_source: 'upload',
        receipt_lock_version: -1
      )
    ).to be_nil
  end
end
