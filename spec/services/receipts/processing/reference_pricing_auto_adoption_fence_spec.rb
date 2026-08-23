require 'rails_helper'

RSpec.describe Receipts::Processing::ReferencePricingAutoAdoptionFence do
  def destination_ocr_result
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def prepared_run(setting_enabled: true, source: 'upload')
    if setting_enabled
      setting = SystemSetting.find_or_initialize_by(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY)
      setting.value = SystemSettings.stored_value(true)
      setting.save!
    else
      SystemSetting.where(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).delete_all
    end
    run = Receipts::Processing::Runs.start(receipt: create(:receipt), source:).run
    Receipts::Processing::Runs.record_ocr_snapshot(run, destination_ocr_result)
    run.reload
  end

  it 'current setting generation・proposal bindingが一致するrunだけをyieldする' do
    run = prepared_run
    writes = 0

    result = described_class.with_locked_run(run:) do |_locked_run|
      writes += 1
      true
    end

    aggregate_failures do
      expect(result).to be_enabled
      expect(result.reason).to eq('enabled')
      expect(writes).to eq(1)
      expect(run.reload.metadata.dig('reference_pricing_auto_adoption_claim', 'proposal_checksum')).to be_present
    end
  end

  it '同じrun/proposalの再実行ではblockを二重実行しない' do
    run = prepared_run
    writes = 0
    operation = proc do
      described_class.with_locked_run(run:) do |_locked_run|
        writes += 1
        true
      end
    end

    first = operation.call
    second = operation.call

    aggregate_failures do
      expect(first).to be_enabled
      expect(second).not_to be_enabled
      expect(second.reason).to eq('already_claimed')
      expect(writes).to eq(1)
    end
  end

  it 'OFF・OFF→ON・開始時OFFをstale generationとして拒否する' do
    run = prepared_run
    setting = SystemSetting.find_by!(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY)
    setting.update!(value: SystemSettings.stored_value(false))
    off = described_class.with_locked_run(run:) { raise 'must not yield' }

    setting.update!(value: SystemSettings.stored_value(true))
    aba = described_class.with_locked_run(run:) { raise 'must not yield' }

    started_off = prepared_run(setting_enabled: false)
    SystemSetting.create!(
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    started_off_result = described_class.with_locked_run(run: started_off) { raise 'must not yield' }

    aggregate_failures do
      expect(off.reason).to eq('current_setting_disabled')
      expect(aba.reason).to eq('setting_generation_mismatch')
      expect(started_off_result.reason).to eq('start_gate_disabled')
    end
  end

  it 'reset/delete-recreate・candidate change・unknown gate・admin retry sourceを拒否する' do
    reset_run = prepared_run
    SystemSetting.find_by!(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).destroy!
    SystemSetting.create!(
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    recreated = described_class.with_locked_run(run: reset_run) { raise 'must not yield' }

    changed_run = prepared_run
    changed_snapshot = changed_run.ocr_result_snapshot.deep_dup
    changed_snapshot.dig('candidates', 'reference_pricing_candidates', 0)['validation_state'] = 'ambiguous'
    changed_run.update!(ocr_result_snapshot: changed_snapshot)
    changed = described_class.with_locked_run(run: changed_run) { raise 'must not yield' }

    missing_gate = prepared_run
    missing_gate.update!(metadata: missing_gate.metadata.except('reference_pricing_auto_adoption_gate'))
    missing = described_class.with_locked_run(run: missing_gate) { raise 'must not yield' }

    retry_run = prepared_run(source: 'admin_retry')
    retry_result = described_class.with_locked_run(run: retry_run) { raise 'must not yield' }

    aggregate_failures do
      expect(recreated.reason).to eq('setting_generation_mismatch')
      expect(changed.reason).to eq('proposal_binding_mismatch')
      expect(missing.reason).to eq('gate_snapshot_invalid')
      expect(retry_result.reason).to eq('run_source_unsupported')
      expect(described_class.serialization_required?(retry_run)).to be(false)
    end
  end

  it 'transaction failure時はrun変更とclaimを一緒にrollbackしてretry可能にする' do
    run = prepared_run

    result = nil
    expect {
      result = described_class.with_locked_run(run:) do |locked_run|
        locked_run.update!(request_reason: 'must rollback')
        raise ActiveRecord::Rollback
      end
    }.not_to change { run.reload.metadata['reference_pricing_auto_adoption_claim'] }

    aggregate_failures do
      expect(result.reason).to eq('operation_not_committed')
      expect(run.reload.request_reason).to be_nil
      expect(
        described_class.with_locked_run(run:) { true }
      ).to be_enabled
    end
  end

  it 'start時は有効でもcurrent OFFならserialized blockを通常Finalize用にyieldしA1 claimは作らない' do
    run = prepared_run
    SystemSetting.find_by!(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY)
      .update!(value: SystemSettings.stored_value(false))
    yielded = nil

    serialized = described_class.with_serialized_run(run:) do |locked_run, gate_result|
      yielded = [ locked_run.id, gate_result.reason ]
      false
    end

    aggregate_failures do
      expect(yielded).to eq([ run.id, 'current_setting_disabled' ])
      expect(serialized.gate_result.reason).to eq('current_setting_disabled')
      expect(serialized).not_to be_operation_committed
      expect(run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end
end
