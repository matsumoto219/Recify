require 'rails_helper'

RSpec.describe UsageCounters do
  describe '.current' do
    it 'counterがない場合は0のentryを返し、DB作成はしない' do
      user = create(:user)

      expect {
        entry = described_class.current(user: user, key: 'receipt_uploads_per_day')

        aggregate_failures do
          expect(entry.used_count).to eq(0)
          expect(entry.used_bytes).to eq(0)
          expect(entry.counter).to be_new_record
        end
      }.not_to change(UsageCounter, :count)
    end
  end

  describe '.increment!' do
    it '初回counterを作成して加算する' do
      user = create(:user)

      entry = described_class.increment!(user: user, key: 'receipt_uploads_per_day', amount: 2, bytes: 123)

      aggregate_failures do
        expect(entry.used_count).to eq(2)
        expect(entry.used_bytes).to eq(123)
        expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(2)
      end
    end
  end

  describe '.check_and_increment!' do
    it 'limit未満ならatomicに加算する' do
      user = create(:user)

      entry = described_class.check_and_increment!(
        user: user,
        key: 'receipt_uploads_per_day',
        amount: 3,
        limit: 5
      )

      aggregate_failures do
        expect(entry.used_count).to eq(3)
        expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(3)
      end
    end

    it 'limit到達後は拒否し、加算しない' do
      user = create(:user)
      described_class.check_and_increment!(user: user, key: 'receipt_uploads_per_day', amount: 5, limit: 5)

      expect {
        described_class.check_and_increment!(user: user, key: 'receipt_uploads_per_day', amount: 1, limit: 5)
      }.to raise_error(UsageLimits::LimitExceeded, 'usage_limit_exceeded')

      expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(5)
    end

    it 'transaction rollback時は加算もrollbackされる' do
      user = create(:user)

      expect {
        UsageCounter.transaction do
          described_class.check_and_increment!(user: user, key: 'receipt_uploads_per_day', amount: 1, limit: 5)
          raise ActiveRecord::Rollback
        end
      }.not_to change(UsageCounter, :count)
    end
  end

  describe '.check!' do
    it 'limit超過を事前検出する' do
      user = create(:user)
      described_class.increment!(user: user, key: 'ocr_jobs_per_day', amount: 3)

      expect {
        described_class.check!(user: user, key: 'ocr_jobs_per_day', amount: 1, limit: 3)
      }.to raise_error(UsageLimits::LimitExceeded)
    end
  end

  describe '.ensure_within_limit!' do
    it '既存利用量が引き下げ後limitを超えている場合は拒否する' do
      user = create(:user)
      described_class.increment!(user: user, key: 'ai_jobs_per_day', amount: 4)

      expect {
        described_class.ensure_within_limit!(user: user, key: 'ai_jobs_per_day', limit: 3)
      }.to raise_error(UsageLimits::LimitExceeded)
    end
  end

  describe '.summary_for' do
    it 'admin表示用summaryを返す' do
      user = create(:user)
      described_class.increment!(user: user, key: 'api_requests_per_day', amount: 10)

      summary = described_class.summary_for(user: user)

      aggregate_failures do
        expect(summary.keys).to include('receipt_uploads_per_day', 'batch_files_per_day', 'api_requests_per_day')
        expect(summary.keys).not_to include('guest_receipt_uploads_per_day')
        expect(summary.fetch('api_requests_per_day').used_count).to eq(10)
        expect(summary.fetch('receipt_uploads_per_day').used_count).to eq(0)
      end
    end
  end

  describe 'guest conversion' do
    it 'guestから本登録化しても同じuser_idの日次counterをリセットしない' do
      guest = create(:user, guest: true)

      described_class.increment!(user: guest, key: 'receipt_uploads_per_day', amount: 5)
      guest.update!(guest: false)

      aggregate_failures do
        expect(guest.reload).not_to be_guest
        expect(described_class.current(user: guest, key: 'receipt_uploads_per_day').used_count).to eq(5)
        expect(UsageCounter.where(user: guest, key: 'receipt_uploads_per_day').count).to eq(1)
      end
    end
  end
end
