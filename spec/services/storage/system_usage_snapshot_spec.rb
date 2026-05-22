require 'rails_helper'

RSpec.describe Storage::SystemUsageSnapshot do
  def create_blob(byte_size:, created_at: Time.current, filename: 'storage-snapshot.jpg')
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
    it 'system/admin dashboard向けのActiveStorage集計を返す' do
      user = create(:user, storage_limit_bytes: 1.gigabyte)
      other_user = create(:user, storage_limit_bytes: 2.gigabytes)
      receipt = create(:receipt, user: user)
      receipt_blob = create_blob(byte_size: 12.kilobytes)
      avatar_blob = create_blob(byte_size: 8.kilobytes)
      orphan_blob = create_blob(byte_size: 4.kilobytes)

      attach_blob(receipt, :image, receipt_blob)
      attach_blob(other_user, :avatar, avatar_blob)

      snapshot = described_class.call

      aggregate_failures do
        expect(snapshot[:total_blob_count]).to eq(3)
        expect(snapshot[:attached_blob_count]).to eq(2)
        expect(snapshot[:orphan_blob_count]).to eq(1)
        expect(snapshot[:total_blob_bytes]).to eq(24.kilobytes)
        expect(snapshot[:attached_blob_bytes]).to eq(20.kilobytes)
        expect(snapshot[:orphan_blob_bytes]).to eq(4.kilobytes)
        expect(snapshot[:user_count]).to eq(2)
        expect(snapshot[:quota_total_bytes]).to eq(3.gigabytes)
        expect(snapshot[:quota_used_bytes]).to eq(20.kilobytes)
        expect(ActiveStorage::Blob.exists?(orphan_blob.id)).to eq(true)
      end
    end
  end
end
