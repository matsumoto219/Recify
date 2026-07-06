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

  def count_sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      name = payload[:name].to_s
      sql = payload[:sql].to_s
      next if %w[SCHEMA TRANSACTION CACHE].include?(name)
      next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries << sql
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end

    queries
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

    it 'receipt analysis runのOCR response artifactを含めない' do
      receipt = create(:receipt, user:)
      run = create(:receipt_analysis_run, receipt:)
      attach_blob(receipt, :image, 12.kilobytes)
      attach_blob(run, :ocr_response_artifact, 5.kilobytes, filename: 'ocr_response.json')

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
    it 'ゲスト50MBで使用量0ならnormalを返す' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      usage = described_class.new(guest)

      aggregate_failures do
        expect(usage.limit_bytes).to eq(50.megabytes)
        expect(usage.used_bytes).to eq(0)
        expect(usage.remaining_bytes).to eq(50.megabytes)
        expect(usage.usage_percentage).to eq(0)
        expect(usage.state).to eq(:normal)
      end
    end

    it 'ゲスト50MBで1MB使用ならnormalを返す' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      attach_blob(guest, :avatar, 1.megabyte)

      aggregate_failures do
        expect(described_class.new(guest).usage_percentage).to eq(2.0)
        expect(described_class.new(guest).state).to eq(:normal)
      end
    end

    it 'ゲスト50MBで使用率80%以上ならwarningを返す' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      attach_blob(guest, :avatar, 40.megabytes)

      aggregate_failures do
        expect(described_class.new(guest).usage_percentage).to eq(80.0)
        expect(described_class.new(guest).state).to eq(:warning)
      end
    end

    it 'ゲスト50MBで使用率95%以上ならerrorを返す' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      attach_blob(guest, :avatar, 48.megabytes)

      aggregate_failures do
        expect(described_class.new(guest).usage_percentage).to eq(96.0)
        expect(described_class.new(guest).state).to eq(:error)
      end
    end

    it '通常ユーザー1GBで使用量0ならnormalを返す' do
      user.update!(storage_limit_bytes: 1.gigabyte)

      expect(described_class.new(user).state).to eq(:normal)
    end

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

    it '大容量上限では残容量が50MB未満ならerrorを返す' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 980.megabytes)

      expect(described_class.new(user).state).to eq(:error)
    end

    it '個別上限100MBで使用量0ならnormalを返す' do
      user.update!(storage_limit_bytes: 100.megabytes)
      usage = described_class.new(user)

      aggregate_failures do
        expect(usage.limit_bytes).to eq(100.megabytes)
        expect(usage.used_bytes).to eq(0)
        expect(usage.state).to eq(:normal)
      end
    end

    it '個別上限100MBで使用率80%以上ならwarningを返す' do
      user.update!(storage_limit_bytes: 100.megabytes)
      attach_blob(user, :avatar, 80.megabytes)

      aggregate_failures do
        expect(described_class.new(user).usage_percentage).to eq(80.0)
        expect(described_class.new(user).state).to eq(:warning)
      end
    end

    it '個別上限100MBで使用率95%以上ならerrorを返す' do
      user.update!(storage_limit_bytes: 100.megabytes)
      attach_blob(user, :avatar, 95.megabytes)

      aggregate_failures do
        expect(described_class.new(user).usage_percentage).to eq(95.0)
        expect(described_class.new(user).state).to eq(:error)
      end
    end

    it 'ゲストから本登録に切り替わると通常上限でstateを再計算する' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      attach_blob(guest, :avatar, 40.megabytes)

      guest_usage = described_class.new(guest)
      used_bytes_before = guest_usage.used_bytes

      aggregate_failures do
        expect(guest_usage.limit_bytes).to eq(50.megabytes)
        expect(guest_usage.state).to eq(:warning)
      end

      guest.update!(guest: false)
      registered_usage = described_class.new(guest)

      aggregate_failures do
        expect(registered_usage.used_bytes).to eq(used_bytes_before)
        expect(registered_usage.limit_bytes).to eq(1.gigabyte)
        expect(registered_usage.state).to eq(:normal)
      end
    end

    it 'SystemSettingsの使用率閾値でwarning/errorを判定する' do
      user.update!(storage_limit_bytes: 1.gigabyte)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 750.megabytes)
      create(:system_setting, key: 'storage.usage_warning_percentage', value: SystemSettings.stored_value(70))
      create(:system_setting, key: 'storage.usage_error_percentage', value: SystemSettings.stored_value(90))

      expect(described_class.new(user).state).to eq(:warning)

      SystemSetting.find_by!(key: 'storage.usage_error_percentage').update!(value: SystemSettings.stored_value(73))

      expect(described_class.new(user).state).to eq(:error)
    end

    it 'SystemSettingsの残容量閾値で大容量上限のwarning/errorを判定する' do
      user.update!(storage_limit_bytes: 5.gigabytes)
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 4.7.gigabytes.to_i)
      create(:system_setting, key: 'storage.warning_remaining_bytes', value: SystemSettings.stored_value(800.megabytes))
      create(:system_setting, key: 'storage.error_remaining_bytes', value: SystemSettings.stored_value(400.megabytes))
      create(:system_setting, key: 'storage.remaining_warning_limit_bytes', value: SystemSettings.stored_value(1.gigabyte))

      expect(described_class.new(user).state).to eq(:error)
    end
  end

  describe 'memoization' do
    it 'derived values do not repeat storage sum or limit lookups on the same calculator' do
      receipt = create(:receipt, user:)
      attach_blob(receipt, :image, 12.kilobytes)
      usage = described_class.new(user)

      allow(UserLimits).to receive(:effective_limit).and_call_original

      queries = count_sql_queries do
        usage.used_bytes
        usage.limit_bytes
        usage.remaining_bytes
        usage.usage_percentage
        usage.state
        usage.can_add?(1.kilobyte)
      end

      attachment_sum_queries = queries.select do |sql|
        sql.include?('active_storage_attachments') && sql.match?(/SUM/i)
      end

      aggregate_failures do
        expect(UserLimits).to have_received(:effective_limit).once
        expect(attachment_sum_queries.size).to eq(1)
        expect(usage.used_bytes).to eq(12.kilobytes)
        expect(usage.limit_bytes).to eq(1.gigabyte)
        expect(usage.remaining_bytes).to eq(1.gigabyte - 12.kilobytes)
        expect(usage.state).to eq(:normal)
      end
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
