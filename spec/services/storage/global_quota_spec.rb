require 'rails_helper'

RSpec.describe Storage::GlobalQuota do
  def create_blob(byte_size:)
    ActiveStorage::Blob.create!(
      key: SecureRandom.uuid,
      filename: 'global-quota.jpg',
      content_type: 'image/jpeg',
      metadata: {},
      service_name: ActiveStorage::Blob.service.name,
      byte_size: byte_size,
      checksum: SecureRandom.base64(16)
    )
  end

  def stub_thresholds(hard_stop_bytes:, warning_percentage: 75, critical_percentage: 90)
    allow(described_class).to receive(:hard_stop_bytes).and_return(hard_stop_bytes)
    allow(described_class).to receive(:warning_percentage).and_return(warning_percentage)
    allow(described_class).to receive(:critical_percentage).and_return(critical_percentage)
  end

  describe '.call' do
    it 'ActiveStorage総量とhard stopからwarning/criticalを割合で計算する' do
      create_blob(byte_size: 2.gigabytes)
      create(
        :system_setting,
        key: 'storage.global_hard_stop_bytes',
        value: SystemSettings.stored_value(10.gigabytes)
      )
      create(
        :system_setting,
        key: 'storage.global_usage_warning_percentage',
        value: SystemSettings.stored_value(70)
      )
      create(
        :system_setting,
        key: 'storage.global_usage_critical_percentage',
        value: SystemSettings.stored_value(85)
      )

      snapshot = described_class.call

      aggregate_failures do
        expect(snapshot.used_bytes).to eq(2.gigabytes)
        expect(snapshot.hard_stop_bytes).to eq(10.gigabytes)
        expect(snapshot.warning_percentage).to eq(70)
        expect(snapshot.critical_percentage).to eq(85)
        expect(snapshot.warning_bytes).to eq((10.gigabytes * 70 / 100.0).ceil)
        expect(snapshot.critical_bytes).to eq((10.gigabytes * 85 / 100.0).ceil)
        expect(snapshot.usage_percentage).to eq(20.0)
        expect(snapshot.state).to eq(:normal)
      end
    end

    it '使用率に応じた状態を返す' do
      stub_thresholds(hard_stop_bytes: 100)

      aggregate_failures do
        create_blob(byte_size: 74)
        expect(described_class.call.state).to eq(:normal)

        ActiveStorage::Blob.delete_all
        create_blob(byte_size: 75)
        expect(described_class.call.state).to eq(:warning)

        ActiveStorage::Blob.delete_all
        create_blob(byte_size: 90)
        expect(described_class.call.state).to eq(:critical)

        ActiveStorage::Blob.delete_all
        create_blob(byte_size: 100)
        expect(described_class.call.state).to eq(:hard_stop)
      end
    end
  end

  describe '.can_add?' do
    it '追加予定サイズ込みでhard stopを超える場合は拒否する' do
      stub_thresholds(hard_stop_bytes: 100)
      create_blob(byte_size: 90)

      aggregate_failures do
        expect(described_class.can_add?(10)).to be(true)
        expect(described_class.can_add?(11)).to be(false)
      end
    end

    it '差し替え対象blobを除外して判定できる' do
      stub_thresholds(hard_stop_bytes: 100)
      blob = create_blob(byte_size: 80)

      aggregate_failures do
        expect(described_class.can_add?(100, excluding_blob: blob)).to be(true)
        expect(described_class.can_add?(101, excluding_blob: blob)).to be(false)
      end
    end
  end
end
