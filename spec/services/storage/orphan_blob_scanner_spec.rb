require 'rails_helper'

RSpec.describe Storage::OrphanBlobScanner do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  def create_blob(byte_size:, created_at:, filename: 'orphan.jpg')
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

  describe '.call' do
    it 'unattachedかつ古いblobだけをorphan候補にする' do
      user = create(:user)
      receipt = create(:receipt, user: user)
      old_orphan = create_blob(byte_size: 12.kilobytes, created_at: 3.days.ago, filename: 'old.jpg')
      new_orphan = create_blob(byte_size: 8.kilobytes, created_at: 1.hour.ago, filename: 'new.jpg')
      attached = create_blob(byte_size: 20.kilobytes, created_at: 3.days.ago, filename: 'attached.jpg')
      attach_blob(receipt, :image, attached)

      result = described_class.call

      aggregate_failures do
        expect(result[:count]).to eq(1)
        expect(result[:bytes]).to eq(12.kilobytes)
        expect(result[:blob_ids]).to eq([ old_orphan.id ])
        expect(result[:blob_ids]).not_to include(new_orphan.id, attached.id)
        expect(result[:sample].first).to include(
          id: old_orphan.id,
          filename: 'old.jpg',
          byte_size: 12.kilobytes
        )
        expect(result[:created_before]).to eq(48.hours.ago.iso8601)
        expect(result[:older_than_seconds]).to eq(48.hours.to_i)
      end
    end

    it 'SystemSettingsの保持時間で検出閾値を変更できる' do
      create(:system_setting, key: 'retention.orphan_blobs_hours', value: SystemSettings.stored_value(72))
      too_new = create_blob(byte_size: 10.kilobytes, created_at: 70.hours.ago)
      old_orphan = create_blob(byte_size: 20.kilobytes, created_at: 73.hours.ago)

      result = described_class.call

      aggregate_failures do
        expect(result[:blob_ids]).to eq([ old_orphan.id ])
        expect(result[:blob_ids]).not_to include(too_new.id)
        expect(result[:created_before]).to eq(72.hours.ago.iso8601)
        expect(result[:older_than_seconds]).to eq(72.hours.to_i)
      end
    end

    it '保持時間を168hに変更するとより古いblobだけを対象にする' do
      create(:system_setting, key: 'retention.orphan_blobs_hours', value: SystemSettings.stored_value(168))
      too_new = create_blob(byte_size: 10.kilobytes, created_at: 6.days.ago)
      old_orphan = create_blob(byte_size: 20.kilobytes, created_at: 8.days.ago)

      result = described_class.call

      aggregate_failures do
        expect(result[:blob_ids]).to eq([ old_orphan.id ])
        expect(result[:blob_ids]).not_to include(too_new.id)
        expect(result[:older_than_seconds]).to eq(168.hours.to_i)
      end
    end

    it 'created_beforeで検出閾値を指定できる' do
      too_new = create_blob(byte_size: 10.kilobytes, created_at: Time.zone.parse('2026-05-22 09:30:00'))
      old_orphan = create_blob(byte_size: 20.kilobytes, created_at: Time.zone.parse('2026-05-22 08:30:00'))

      result = described_class.call(created_before: Time.zone.parse('2026-05-22 09:00:00'))

      aggregate_failures do
        expect(result[:blob_ids]).to eq([ old_orphan.id ])
        expect(result[:blob_ids]).not_to include(too_new.id)
        expect(result[:older_than_seconds]).to be_nil
      end
    end

    it 'limitで候補件数を制限できる' do
      first = create_blob(byte_size: 1.kilobyte, created_at: 3.days.ago)
      second = create_blob(byte_size: 2.kilobytes, created_at: 3.days.ago)
      third = create_blob(byte_size: 3.kilobytes, created_at: 25.hours.ago)

      result = described_class.call(limit: 2)

      aggregate_failures do
        expect(result[:count]).to eq(2)
        expect(result[:bytes]).to eq(3.kilobytes)
        expect(result[:blob_ids]).to eq([ first.id, second.id ])
        expect(result[:blob_ids]).not_to include(third.id)
      end
    end
  end
end
