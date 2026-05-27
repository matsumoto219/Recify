require 'rails_helper'

RSpec.describe Storage::UsageCalculator do
  let(:user) { create(:user, storage_limit_bytes: 1.gigabyte) }

  def attach_blob(record, name, byte_size, filename: "#{name}.jpg")
    blob = ActiveStorage::Blob.create!(
      key: SecureRandom.uuid,
      filename: filename,
      content_type: 'image/jpeg',
      metadata: {},
      service_name: ActiveStorage::Blob.service.name,
      byte_size: byte_size,
      checksum: SecureRandom.base64(16)
    )
    ActiveStorage::Attachment.create!(
      name: name.to_s,
      record: record,
      blob: blob
    )
    blob
  end

  describe '#used_bytes' do
    it 'receipt image byte_sizeを含む' do
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 12.kilobytes)

      expect(described_class.new(user).used_bytes).to eq(12.kilobytes)
    end

    it 'avatar byte_sizeを含む' do
      attach_blob(user, :avatar, 8.kilobytes)

      expect(described_class.new(user).used_bytes).to eq(8.kilobytes)
    end

    it 'receipt imageとavatarを合算する' do
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 12.kilobytes)
      attach_blob(user, :avatar, 8.kilobytes)

      expect(described_class.new(user).used_bytes).to eq(20.kilobytes)
    end

    it '他ユーザーのblobを含めない' do
      receipt = create(:receipt, user:)
      other_user = create(:user)
      other_receipt = create(:receipt, user: other_user)
      attach_blob(receipt, :image, 12.kilobytes)
      attach_blob(other_receipt, :image, 40.kilobytes)
      attach_blob(other_user, :avatar, 40.kilobytes)

      expect(described_class.new(user).used_bytes).to eq(12.kilobytes)
    end

    it 'ActiveStorage variantsを含めない' do
      receipt = create(:receipt, user:)
      blob = attach_blob(receipt, :image, 12.kilobytes)
      ActiveStorage::VariantRecord.create!(blob:, variation_digest: SecureRandom.hex(16))

      expect(described_class.new(user).used_bytes).to eq(12.kilobytes)
    end
  end

  describe '#state' do
    it '通常範囲ではnormalを返す' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 100.megabytes)

      expect(described_class.new(user).state).to eq(:normal)
    end

    it '残容量が200MB未満ならwarningを返す' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 850.megabytes)

      expect(described_class.new(user).state).to eq(:warning)
    end

    it '使用率80%以上かつ残容量1GB未満ならwarningを返す' do
      user.update!(storage_limit_bytes: 5.gigabytes)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 4.1.gigabytes.to_i)

      expect(described_class.new(user).state).to eq(:warning)
    end

    it '使用率95%以上ならerrorを返す' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 973.megabytes)

      expect(described_class.new(user).state).to eq(:error)
    end

    it '残容量が50MB未満ならerrorを返す' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 980.megabytes)

      expect(described_class.new(user).state).to eq(:error)
    end
  end

  describe '#can_add?' do
    it 'user overrideのstorage_bytesを上限として使う' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      create(:user_limit_override, user: user, key: 'storage_bytes', value: { 'value' => 2.megabytes })
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 1.megabyte)

      aggregate_failures do
        expect(described_class.new(user).limit_bytes).to eq(2.megabytes)
        expect(described_class.new(user).can_add?(1.megabyte + 1)).to be(false)
      end
    end

    it '上限内ならtrueを返す' do
      user.update!(storage_limit_bytes: 100.kilobytes)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 40.kilobytes)

      expect(described_class.new(user).can_add?(60.kilobytes)).to be(true)
    end

    it '上限を超える場合はfalseを返す' do
      user.update!(storage_limit_bytes: 100.kilobytes)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 40.kilobytes)

      expect(described_class.new(user).can_add?(61.kilobytes)).to be(false)
    end

    it 'excluding_blobで既存blobを差し引ける' do
      user.update!(storage_limit_bytes: 100.kilobytes)
      receipt = create(:receipt, user:)
      old_blob = attach_blob(receipt, :image, 80.kilobytes)

      expect(described_class.new(user).can_add?(80.kilobytes, excluding_blob: old_blob)).to be(true)
    end
  end
end
