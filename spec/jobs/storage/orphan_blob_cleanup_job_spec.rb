require 'rails_helper'

RSpec.describe Storage::OrphanBlobCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  def create_blob(byte_size:, created_at:, filename: 'cleanup.jpg')
    ActiveStorage::Blob.create!(
      key: SecureRandom.uuid,
      filename: filename,
      content_type: 'image/jpeg',
      metadata: {},
      service_name: ActiveStorage::Blob.service.name,
      byte_size: byte_size,
      checksum: SecureRandom.base64(16),
      created_at: created_at
    )
  end

  def attach_blob(record, name, blob)
    ActiveStorage::Attachment.create!(
      name: name.to_s,
      record: record,
      blob: blob
    )
  end

  describe '#perform' do
    it 'default dry_runでは削除しない' do
      old_orphan = create_blob(byte_size: 12.kilobytes, created_at: 3.days.ago)

      result = described_class.perform_now

      aggregate_failures do
        expect(result).to include(
          dry_run: true,
          scanned_count: 1,
          purged_count: 0,
          skipped_count: 1,
          bytes: 12.kilobytes,
          failed_count: 0
        )
        expect(ActiveStorage::Blob.exists?(old_orphan.id)).to eq(true)
      end
    end

    it 'dry_run:nilでも削除しない' do
      old_orphan = create_blob(byte_size: 12.kilobytes, created_at: 3.days.ago)

      result = described_class.perform_now(dry_run: nil)

      aggregate_failures do
        expect(result).to include(dry_run: true, scanned_count: 1, purged_count: 0, skipped_count: 1)
        expect(ActiveStorage::Blob.exists?(old_orphan.id)).to eq(true)
      end
    end

    it 'dry_run:falseを明示した場合だけ対象blobをpurgeする' do
      old_orphan = create_blob(byte_size: 12.kilobytes, created_at: 3.days.ago)

      result = described_class.perform_now(dry_run: false)

      aggregate_failures do
        expect(result).to include(
          dry_run: false,
          scanned_count: 1,
          purged_count: 1,
          skipped_count: 0,
          bytes: 12.kilobytes,
          failed_count: 0
        )
        expect(ActiveStorage::Blob.exists?(old_orphan.id)).to eq(false)
      end
    end

    it '新しいunattached blobは削除しない' do
      new_orphan = create_blob(byte_size: 8.kilobytes, created_at: 1.hour.ago)

      result = described_class.perform_now(dry_run: false)

      aggregate_failures do
        expect(result).to include(scanned_count: 0, purged_count: 0, skipped_count: 0)
        expect(ActiveStorage::Blob.exists?(new_orphan.id)).to eq(true)
      end
    end

    it 'attached blobは削除しない' do
      user = create(:user)
      receipt = create(:receipt, user: user)
      attached = create_blob(byte_size: 20.kilobytes, created_at: 3.days.ago)
      attach_blob(receipt, :image, attached)

      result = described_class.perform_now(dry_run: false)

      aggregate_failures do
        expect(result).to include(scanned_count: 0, purged_count: 0, skipped_count: 0)
        expect(ActiveStorage::Blob.exists?(attached.id)).to eq(true)
      end
    end

    it 'limitが効く' do
      first = create_blob(byte_size: 1.kilobyte, created_at: 3.days.ago)
      second = create_blob(byte_size: 2.kilobytes, created_at: 3.days.ago)
      third = create_blob(byte_size: 3.kilobytes, created_at: 25.hours.ago)

      result = described_class.perform_now(dry_run: false, limit: 2)

      aggregate_failures do
        expect(result).to include(scanned_count: 2, purged_count: 2, skipped_count: 0, bytes: 3.kilobytes)
        expect(ActiveStorage::Blob.exists?(first.id)).to eq(false)
        expect(ActiveStorage::Blob.exists?(second.id)).to eq(false)
        expect(ActiveStorage::Blob.exists?(third.id)).to eq(true)
      end
    end

    it '結果Hashと同じキーをログに出す' do
      create_blob(byte_size: 12.kilobytes, created_at: 3.days.ago)
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        include(
          'dry_run=true',
          'scanned_count=1',
          'purged_count=0',
          'skipped_count=1',
          'bytes=12288',
          'failed_count=0'
        )
      )
    end

    it 'Storage親入口からorphan blob scanを実行する' do
      scan = {
        count: 0,
        bytes: 0,
        blob_ids: [],
        sample: [],
        created_before: 1.day.ago.iso8601,
        older_than_seconds: 86_400
      }

      allow(Storage).to receive(:orphan_blob_scan).and_return(scan)

      result = described_class.perform_now(dry_run: false, limit: 5)

      aggregate_failures do
        expect(Storage).to have_received(:orphan_blob_scan).with(
          created_before: nil,
          older_than: nil,
          limit: 5
        )
        expect(result).to include(scanned_count: 0, purged_count: 0)
      end
    end

    it 'SystemSettingsの保持時間をcleanup対象判定に使う' do
      create(:system_setting, key: 'retention.orphan_blobs_hours', value: SystemSettings.stored_value(72))
      too_new = create_blob(byte_size: 8.kilobytes, created_at: 70.hours.ago)
      old_orphan = create_blob(byte_size: 12.kilobytes, created_at: 73.hours.ago)

      result = described_class.perform_now(dry_run: true)

      aggregate_failures do
        expect(result).to include(dry_run: true, scanned_count: 1, skipped_count: 1, bytes: 12.kilobytes)
        expect(ActiveStorage::Blob.exists?(too_new.id)).to eq(true)
        expect(ActiveStorage::Blob.exists?(old_orphan.id)).to eq(true)
      end
    end
  end
end
