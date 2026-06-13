require 'rails_helper'

RSpec.describe Usage do
  let(:user) { build_stubbed(:user) }

  describe '.consume_receipt_upload!' do
    it 'receipt upload counterをlimit付きで加算する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'receipt_uploads_per_day')
        .and_return(50)
      allow(Usage::Counters).to receive(:check_and_increment!).and_return(true)

      expect(described_class.consume_receipt_upload!(user: user)).to eq(true)

      expect(Usage::Counters).to have_received(:check_and_increment!).with(
        user: user,
        key: 'receipt_uploads_per_day',
        amount: 1,
        limit: 50
      )
    end
  end

  describe '.consume_manual_receipt!' do
    it 'manual receipt counterをlimit付きで加算する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'manual_receipts_per_day')
        .and_return(50)
      allow(Usage::Counters).to receive(:check_and_increment!).and_return(true)

      expect(described_class.consume_manual_receipt!(user: user)).to eq(true)

      expect(Usage::Counters).to have_received(:check_and_increment!).with(
        user: user,
        key: 'manual_receipts_per_day',
        amount: 1,
        limit: 50
      )
    end
  end

  describe '.consume_batch_upload!' do
    it 'batch upload counterを指定件数で加算する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'batch_files_per_day')
        .and_return(5)
      allow(Usage::Counters).to receive(:check_and_increment!).and_return(true)

      described_class.consume_batch_upload!(user: user, amount: 3)

      expect(Usage::Counters).to have_received(:check_and_increment!).with(
        user: user,
        key: 'batch_files_per_day',
        amount: 3,
        limit: 5
      )
    end
  end

  describe '.consume_retry_operation!' do
    it 'retry operation counterを加算する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'retry_operations_per_day')
        .and_return(10)
      allow(Usage::Counters).to receive(:check_and_increment!).and_return(true)

      described_class.consume_retry_operation!(user: user)

      expect(Usage::Counters).to have_received(:check_and_increment!).with(
        user: user,
        key: 'retry_operations_per_day',
        amount: 1,
        limit: 10
      )
    end
  end

  describe '.ensure_ocr_job_within_limit!' do
    it 'Usage::Limitsへ委譲する' do
      allow(Usage::Limits).to receive(:ensure_ocr_job_within_limit!).with(user: user).and_return(:ok)

      expect(described_class.ensure_ocr_job_within_limit!(user: user)).to eq(:ok)
    end
  end

  describe '.consume_ocr_job!' do
    it 'Usage::Limitsへ委譲する' do
      allow(Usage::Limits).to receive(:consume_ocr_job!).with(user: user).and_return(:ok)

      expect(described_class.consume_ocr_job!(user: user)).to eq(:ok)
    end
  end

  describe '.consume_ai_job!' do
    it 'Usage::Limitsへ委譲する' do
      allow(Usage::Limits).to receive(:consume_ai_job!).with(user: user).and_return(:ok)

      expect(described_class.consume_ai_job!(user: user)).to eq(:ok)
    end
  end

  describe '.ensure_ai_job_within_limit!' do
    it 'Usage::Limitsへ委譲する' do
      allow(Usage::Limits).to receive(:ensure_ai_job_within_limit!).with(user: user).and_return(:ok)

      expect(described_class.ensure_ai_job_within_limit!(user: user)).to eq(:ok)
    end
  end

  describe '.mark_analysis_run_blocked!' do
    it 'Usage::Limitsへ委譲する' do
      run = instance_double(ReceiptAnalysisRun)
      allow(Usage::Limits).to receive(:mark_analysis_run_blocked!).with(run: run, stage: 'ocr').and_return(nil)

      expect(described_class.mark_analysis_run_blocked!(run: run, stage: 'ocr')).to be_nil
    end
  end

  describe '.counter_summary_for' do
    it 'Usage::Countersへ委譲する' do
      summary = { 'receipt_uploads_per_day' => double('entry') }
      allow(Usage::Counters).to receive(:summary_for).with(user: user).and_return(summary)

      expect(described_class.counter_summary_for(user: user)).to eq(summary)
    end
  end

  describe '.limit_summary_for' do
    it 'UserLimitsへ委譲する' do
      summary = [ double('limit_entry') ]
      allow(UserLimits).to receive(:summary_for).with(user: user).and_return(summary)

      expect(described_class.limit_summary_for(user: user)).to eq(summary)
    end
  end

  describe '.effective_limit' do
    it 'UserLimitsへ委譲する' do
      allow(UserLimits).to receive(:effective_limit).with(user: user, key: 'storage_bytes').and_return(100)

      expect(described_class.effective_limit(user: user, key: 'storage_bytes')).to eq(100)
    end
  end
end
