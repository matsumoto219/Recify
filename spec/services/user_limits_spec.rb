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

      entry = described_class.entry_for(user: guest, key: 'storage_bytes')

      aggregate_failures do
        expect(entry.value).to eq(50.megabytes)
        expect(entry.source).to eq('guest_global_default')
      end
    end

    it 'guestにはguest用のupload / batch / OCR / AI limitを適用する' do
      guest = create(:user, guest: true)

      aggregate_failures do
        %w[receipt_uploads_per_day batch_files_per_day ocr_jobs_per_day ai_jobs_per_day].each do |key|
          entry = described_class.entry_for(user: guest, key: key)
          expect(entry.value).to eq(5)
          expect(entry.source).to eq('guest_global_default')
        end
      end
    end

    it '本登録ユーザーには通常limitを適用する' do
      user = create(:user)

      aggregate_failures do
        %w[receipt_uploads_per_day batch_files_per_day ocr_jobs_per_day ai_jobs_per_day].each do |key|
          entry = described_class.entry_for(user: user, key: key)
          expect(entry.value).to eq(50)
          expect(entry.source).to eq('global_default')
        end
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

    it 'summary_forはoverrideとglobal limitを一括取得する' do
      user = create(:user)
      create(:user_limit_override, user: user, key: 'receipt_uploads_per_day', value: { 'value' => 90 })

      queries = count_sql_queries do
        summary = described_class.summary_for(user: user)
        expect(summary.find { |entry| entry.key == 'receipt_uploads_per_day' }.value).to eq(90)
      end

      aggregate_failures do
        expect(queries.count { |sql| sql.include?('"user_limit_overrides"') }).to eq(1)
        expect(queries.count { |sql| sql.include?('"system_settings"') }).to eq(1)
      end
    end

    it 'guestから本登録化するとeffective limitだけ通常ユーザー側へ切り替わる' do
      guest = create(:user, guest: true, storage_limit_bytes: 1.gigabyte)
      guest.avatar.attach(io: StringIO.new('avatar-bytes'), filename: 'avatar.png', content_type: 'image/png')
      Usage::Counters.increment!(user: guest, key: 'receipt_uploads_per_day', amount: 5)
      used_bytes_before = guest.storage_usage.used_bytes

      aggregate_failures do
        expect(described_class.effective_limit(user: guest, key: 'storage_bytes')).to eq(50.megabytes)
        expect(described_class.effective_limit(user: guest, key: 'receipt_uploads_per_day')).to eq(5)
        expect(used_bytes_before).to be_positive
      end

      guest.update!(guest: false)

      aggregate_failures do
        expect(described_class.effective_limit(user: guest, key: 'storage_bytes')).to eq(1.gigabyte)
        expect(described_class.effective_limit(user: guest, key: 'receipt_uploads_per_day')).to eq(50)
        expect(guest.storage_usage.used_bytes).to eq(used_bytes_before)
        expect(UsageCounter.find_by!(user: guest, key: 'receipt_uploads_per_day').used_count).to eq(5)
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

  def count_sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      name = payload[:name].to_s
      sql = payload[:sql].to_s.squish
      next if name == 'SCHEMA' || name == 'TRANSACTION' || payload[:cached]
      next if sql.include?('schema_migrations') || sql.include?('ar_internal_metadata')

      queries << sql
    end

    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        yield
      end
    end
    queries
  end
end
