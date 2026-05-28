require 'rails_helper'

RSpec.describe Storage do
  describe '.purge_attachment' do
    it 'AttachmentPurgerへ委譲する' do
      attachment = instance_double(ActiveStorage::Attached::One)

      allow(Storage::AttachmentPurger).to receive(:call).with(attachment).and_return(true)

      expect(described_class.purge_attachment(attachment)).to eq(true)
    end
  end

  describe '.system_usage_snapshot' do
    it 'SystemUsageSnapshotへ委譲する' do
      snapshot = { total_blob_count: 1 }

      allow(Storage::SystemUsageSnapshot).to receive(:call).and_return(snapshot)

      expect(described_class.system_usage_snapshot).to eq(snapshot)
    end
  end

  describe '.orphan_blob_scan' do
    it 'OrphanBlobScannerへ委譲する' do
      result = { count: 1 }

      allow(Storage::OrphanBlobScanner).to receive(:call).with(limit: 5).and_return(result)

      expect(described_class.orphan_blob_scan(limit: 5)).to eq(result)
    end
  end

  describe '.usage_calculator' do
    it 'UsageCalculatorを返す' do
      user = build(:user)

      expect(described_class.usage_calculator(user)).to be_a(Storage::UsageCalculator)
    end
  end
end
