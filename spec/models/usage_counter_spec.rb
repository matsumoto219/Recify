require 'rails_helper'

RSpec.describe UsageCounter do
  describe 'validations' do
    it 'key/user/period/period_start単位でDB一意にする' do
      existing = create(:usage_counter, key: 'receipt_uploads_per_day')

      expect {
        create(
          :usage_counter,
          user: existing.user,
          key: existing.key,
          period: existing.period,
          period_start: existing.period_start
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'used_count と used_bytes は負数を拒否する' do
      counter = build(:usage_counter, used_count: -1, used_bytes: -1)

      expect(counter).not_to be_valid
      expect(counter.errors[:used_count]).to be_present
      expect(counter.errors[:used_bytes]).to be_present
    end
  end
end
