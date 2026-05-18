require 'rails_helper'

RSpec.describe User, type: :model do
  describe 'storage_limit_bytes validation' do
    it '0以下は不正にする' do
      user = build(:user, storage_limit_bytes: 0)

      expect(user).not_to be_valid
    end
  end

  describe 'storage wrapper methods' do
    let(:user) { create(:user, storage_limit_bytes: 100.kilobytes) }

    def attach_avatar(byte_size)
      blob = ActiveStorage::Blob.create!(
        key: SecureRandom.uuid,
        filename: 'avatar.jpg',
        content_type: 'image/jpeg',
        metadata: {},
        service_name: ActiveStorage::Blob.service.name,
        byte_size: byte_size,
        checksum: SecureRandom.base64(16)
      )
      ActiveStorage::Attachment.create!(
        name: 'avatar',
        record: user,
        blob: blob
      )
      blob
    end

    it 'storage_usageを返す' do
      expect(user.storage_usage).to be_a(Storage::UsageCalculator)
    end

    it 'storage_used_bytesを返す' do
      attach_avatar(10.kilobytes)

      expect(user.storage_used_bytes).to eq(10.kilobytes)
    end

    it 'storage_can_add?で追加可能容量を判定する' do
      attach_avatar(90.kilobytes)

      aggregate_failures do
        expect(user.storage_can_add?(10.kilobytes)).to be(true)
        expect(user.storage_can_add?(11.kilobytes)).to be(false)
      end
    end
  end
end
