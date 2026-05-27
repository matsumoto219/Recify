require 'rails_helper'

RSpec.describe UserLimitOverride do
  describe 'validations' do
    it 'allowlistされたkeyと整数valueを許可する' do
      override = build(:user_limit_override, key: 'receipt_uploads_per_day', value: { 'value' => 75 })

      aggregate_failures do
        expect(override).to be_valid
        expect(override.integer_value).to eq(75)
      end
    end

    it 'unknown keyを拒否する' do
      override = build(:user_limit_override, key: 'secret.provider_api_key', value: { 'value' => 75 })

      expect(override).not_to be_valid
      expect(override.errors[:key]).to be_present
    end

    it '範囲外valueを拒否する' do
      override = build(:user_limit_override, key: 'retry_operations_per_day', value: { 'value' => 500 })

      expect(override).not_to be_valid
      expect(override.errors[:value]).to include('above_max')
    end

    it 'userごとのkey重複を拒否する' do
      existing = create(:user_limit_override, key: 'ocr_jobs_per_day', value: { 'value' => 40 })
      duplicate = build(:user_limit_override, user: existing.user, key: 'ocr_jobs_per_day', value: { 'value' => 50 })

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:key]).to be_present
    end
  end

  describe '#expired?' do
    it 'expires_atが過去ならtrue' do
      override = build(:user_limit_override, expires_at: 1.minute.ago)

      expect(override.expired?).to be(true)
    end
  end
end
