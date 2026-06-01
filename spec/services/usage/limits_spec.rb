require 'rails_helper'

RSpec.describe Usage::Limits do
  let(:user) { build_stubbed(:user) }

  describe '.consume_ocr_job!' do
    it 'OCR job counterをlimit付きで加算する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'ocr_jobs_per_day')
        .and_return(50)
      allow(Usage::Counters).to receive(:check_and_increment!).and_return(true)

      described_class.consume_ocr_job!(user: user)

      expect(Usage::Counters).to have_received(:check_and_increment!).with(
        user: user,
        key: 'ocr_jobs_per_day',
        amount: 1,
        limit: 50
      )
    end
  end

  describe '.ensure_ocr_job_within_limit!' do
    it 'OCR job counterをlimit内か検証する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'ocr_jobs_per_day')
        .and_return(50)
      allow(Usage::Counters).to receive(:ensure_within_limit!).and_return(true)

      described_class.ensure_ocr_job_within_limit!(user: user)

      expect(Usage::Counters).to have_received(:ensure_within_limit!).with(
        user: user,
        key: 'ocr_jobs_per_day',
        limit: 50
      )
    end
  end

  describe '.consume_ai_job!' do
    it 'AI job counterをlimit付きで加算する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'ai_jobs_per_day')
        .and_return(50)
      allow(Usage::Counters).to receive(:check_and_increment!).and_return(true)

      described_class.consume_ai_job!(user: user)

      expect(Usage::Counters).to have_received(:check_and_increment!).with(
        user: user,
        key: 'ai_jobs_per_day',
        amount: 1,
        limit: 50
      )
    end
  end
end
