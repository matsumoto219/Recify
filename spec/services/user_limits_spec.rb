require 'rails_helper'

RSpec.describe UserLimits do
  describe '.definitions' do
    it 'user別override対象keyだけを返す' do
      expect(described_class.definitions.keys).to contain_exactly(
        'receipt_uploads_per_day',
        'batch_files_per_day',
        'ocr_jobs_per_day',
        'ai_jobs_per_day',
        'retry_operations_per_day',
        'storage_bytes',
        'api_requests_per_minute',
        'api_requests_per_day'
      )
    end
  end

  describe '.effective_limit and .entry_for' do
    it 'global defaultをfallbackとして返す' do
      user = create(:user)

      entry = described_class.entry_for(user: user, key: 'receipt_uploads_per_day')

      aggregate_failures do
        expect(entry.value).to eq(50)
        expect(entry.source).to eq('global_default')
        expect(entry.global_value).to eq(50)
        expect(described_class.effective_limit(user: user, key: 'receipt_uploads_per_day')).to eq(50)
      end
    end

    it 'activeなuser overrideを優先する' do
      user = create(:user)
      override = create(:user_limit_override, user: user, key: 'receipt_uploads_per_day', value: { 'value' => 90 })

      entry = described_class.entry_for(user: user, key: 'receipt_uploads_per_day')

      aggregate_failures do
        expect(entry.value).to eq(90)
        expect(entry.source).to eq('override')
        expect(entry.override).to eq(override)
      end
    end

    it 'disabled overrideは無視する' do
      user = create(:user)
      create(:user_limit_override, user: user, key: 'receipt_uploads_per_day', value: { 'value' => 90 }, enabled: false)

      expect(described_class.entry_for(user: user, key: 'receipt_uploads_per_day').source).to eq('global_default')
    end

    it 'expired overrideは無視する' do
      user = create(:user)
      create(
        :user_limit_override,
        user: user,
        key: 'receipt_uploads_per_day',
        value: { 'value' => 90 },
        expires_at: 1.minute.ago
      )

      expect(described_class.entry_for(user: user, key: 'receipt_uploads_per_day').source).to eq('global_default')
    end

    it 'storage_bytesはusers.storage_limit_bytesをfallbackにする' do
      user = create(:user, storage_limit_bytes: 2.gigabytes)

      entry = described_class.entry_for(user: user, key: 'storage_bytes')

      aggregate_failures do
        expect(entry.value).to eq(2.gigabytes)
        expect(entry.source).to eq('user_storage_limit')
        expect(entry.base_value).to eq(2.gigabytes)
      end
    end

    it 'guest storageは既存storage limitとguest global capの小さい方を返す' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      create(
        :system_setting,
        key: 'limits.guest_storage_bytes',
        value: SystemSettings.stored_value(25.megabytes)
      )

      entry = described_class.entry_for(user: guest, key: 'storage_bytes')

      aggregate_failures do
        expect(entry.value).to eq(25.megabytes)
        expect(entry.source).to eq('guest_global_default')
      end
    end

    it 'guest storageもactive overrideがあればoverrideを優先する' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      create(:user_limit_override, user: guest, key: 'storage_bytes', value: { 'value' => 200.megabytes })

      entry = described_class.entry_for(user: guest, key: 'storage_bytes')

      aggregate_failures do
        expect(entry.value).to eq(200.megabytes)
        expect(entry.source).to eq('override')
      end
    end

    it 'API limitは予約keyとしてsummaryに含める' do
      user = create(:user)

      api_entry = described_class.entry_for(user: user, key: 'api_requests_per_day')

      aggregate_failures do
        expect(api_entry.value).to eq(1000)
        expect(api_entry.api_reservation).to be(true)
      end
    end
  end

  describe '.cast_value' do
    it '整数範囲を検証する' do
      aggregate_failures do
        expect(described_class.cast_value('storage_bytes', { 'value' => 5.megabytes })).to eq(5.megabytes)
        expect {
          described_class.cast_value('storage_bytes', { 'value' => 1.kilobyte })
        }.to raise_error(UserLimits::ValidationError, 'below_min')
        expect {
          described_class.cast_value('secret', { 'value' => 1 })
        }.to raise_error(UserLimits::ValidationError, 'unknown_key')
      end
    end
  end
end
