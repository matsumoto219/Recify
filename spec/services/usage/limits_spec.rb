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
      allow(Usage::Counters).to receive(:check!).and_return(true)

      described_class.ensure_ocr_job_within_limit!(user: user)

      expect(Usage::Counters).to have_received(:check!).with(
        user: user,
        key: 'ocr_jobs_per_day',
        amount: 1,
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

  describe '.ensure_ai_job_within_limit!' do
    it 'AI job counterをlimit内か検証する' do
      allow(UserLimits).to receive(:effective_limit)
        .with(user: user, key: 'ai_jobs_per_day')
        .and_return(50)
      allow(Usage::Counters).to receive(:check!).and_return(true)

      described_class.ensure_ai_job_within_limit!(user: user)

      expect(Usage::Counters).to have_received(:check!).with(
        user: user,
        key: 'ai_jobs_per_day',
        amount: 1,
        limit: 50
      )
    end
  end

  describe '.mark_analysis_run_blocked!' do
    it 'runのfailed更新が失敗した場合はreceiptを先にfailedへ変更しない' do
      receipt = create(:receipt, :processing, :with_image)
      run = ReceiptAnalysisRuns.start(receipt:, source: 'upload').run
      allow(ReceiptAnalysisRuns).to receive(:fail)
        .and_raise(ActiveRecord::StatementInvalid, 'forced run update failure')

      expect do
        described_class.mark_analysis_run_blocked!(run:, stage: :ocr)
      end.to raise_error(ActiveRecord::StatementInvalid, 'forced run update failure')

      aggregate_failures do
        expect(run.reload).to have_attributes(status: 'queued', error_code: nil)
        expect(receipt.reload).to have_attributes(status: 'processing', processing_error_code: nil)
      end
    end

    it 'receiptのfailed更新が失敗した場合はrun終端もrollbackする' do
      receipt = create(:receipt, :processing, :with_image)
      run = ReceiptAnalysisRuns.start(receipt:, source: 'upload').run
      allow(run).to receive(:receipt).and_return(receipt)
      allow(receipt).to receive(:update!).and_wrap_original do |original, *args, **kwargs|
        attributes = args.first || kwargs
        raise ActiveRecord::StatementInvalid, 'forced receipt update failure' if attributes[:status] == 'failed'

        original.call(*args, **kwargs)
      end

      expect do
        described_class.mark_analysis_run_blocked!(run:, stage: :ocr)
      end.to raise_error(ActiveRecord::StatementInvalid, 'forced receipt update failure')

      aggregate_failures do
        expect(run.reload).to have_attributes(status: 'queued', error_code: nil)
        expect(receipt.reload).to have_attributes(status: 'processing', processing_error_code: nil)
      end
    end

    it 'usage limit超過の終端処理をReceiptAnalysisRunsへ委譲する' do
      receipt = create(:receipt, :processing, :with_image)
      run = ReceiptAnalysisRuns.start(receipt:, source: 'upload').run

      described_class.mark_analysis_run_blocked!(run:, stage: :ai)

      aggregate_failures do
        expect(run.reload).to have_attributes(
          status: 'failed',
          error_stage: 'ai',
          error_code: 'usage_limit_exceeded'
        )
        expect(receipt.reload).to have_attributes(
          status: 'failed',
          processing_error_code: 'usage_limit_exceeded'
        )
      end
    end
  end
end
