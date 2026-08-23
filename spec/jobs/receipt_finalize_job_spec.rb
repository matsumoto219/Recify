require 'rails_helper'

RSpec.describe ReceiptFinalizeJob, type: :job do
  include ActiveJob::TestHelper

  def reference_pricing_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def reference_pricing_finalize_decision
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: :ocr_only,
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
  end

  def enqueued_finalize_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      (job[:job] || job['job']) == described_class
    end
  end

  describe '.queue_name' do
    it 'receipt_finalize queueを使う' do
      expect(described_class.queue_name).to eq('receipt_finalize')
    end
  end

  describe '#perform' do
    it 'Pipeline親入口だけを呼ぶ' do
      run = create(:receipt_analysis_run)
      allow(Receipts::Processing).to receive(:run_finalize)

      described_class.perform_now(run_id: run.id)

      expect(Receipts::Processing).to have_received(:run_finalize).with(run)
    end

    it '存在しないrunは安全にdiscardする' do
      allow(Receipts::Processing).to receive(:run_finalize)

      expect do
        described_class.perform_now(run_id: -1)
      end.not_to raise_error

      expect(Receipts::Processing).not_to have_received(:run_finalize)
    end

    it 'run_id keyword以外の呼び出しは受け付けない' do
      run = create(:receipt_analysis_run)

      expect { described_class.perform_now(run.id) }.to raise_error(ArgumentError)
    end

    it 'terminal runのreplayではreceiptを変更しない' do
      receipt = create(:receipt, store_name: 'Replay Safe', total_amount: 1000, status: 'completed')
      run = create(:receipt_analysis_run, :succeeded, receipt: receipt)

      expect do
        described_class.perform_now(run_id: run.id)
      end.not_to change { receipt.reload.attributes.slice('status', 'store_name', 'total_amount', 'updated_at') }

      expect(run.reload.status).to eq('succeeded')
    end

    it '同じrunのFinalize Jobを再実行しても保存処理は1回だけにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      decision = Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'fail_receipt',
        error_code: 'ocr_api_error',
        receipt_attributes: {}
      )
      Receipts::Processing.record_finalize_decision(run, decision)
      allow(Receipts::Processing::Pipeline).to receive(:finalize).and_call_original

      2.times { described_class.perform_now(run_id: run.id) }

      aggregate_failures do
        expect(Receipts::Processing::Pipeline).to have_received(:finalize).once
        expect(receipt.reload.status).to eq('failed')
        expect(run.reload.status).to eq('succeeded')
      end
    end

    it 'A1 serialized transactionのretryable errorだけをbounded retryへ送る' do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      run = create(:receipt_analysis_run)
      error = Receipts::Processing::RetryableFinalizeError.new('transient_finalize_database_error')
      allow(Receipts::Processing).to receive(:run_finalize).with(run).and_raise(error)

      expect do
        described_class.perform_now(run_id: run.id)
      end.to have_enqueued_job(described_class).with(run_id: run.id)

      expect(run.reload).to be_active
    end

    it '通常Finalizeのraw DB errorはA1 retry queueへ広げない' do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      run = create(:receipt_analysis_run)
      error = ActiveRecord::Deadlocked.new('standard finalize database detail')
      allow(Receipts::Processing).to receive(:run_finalize).with(run).and_raise(error)

      expect { described_class.perform_now(run_id: run.id) }.to raise_error(error)
      expect(enqueued_finalize_jobs).to be_empty
    end

    it 'A1 transactionのdeadlock後にJob retryしてもauthorityを1回だけ採用する' do
      create(
        :system_setting,
        key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
        value: SystemSettings.stored_value(true)
      )

      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = Receipts::Processing.start(receipt:, source: 'upload').run
      Receipts::Processing.record_ocr_snapshot(run, reference_pricing_ocr_result)
      Receipts::Processing.record_finalize_decision(run, reference_pricing_finalize_decision)
      calls = 0
      allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
        calls += 1
        raise ActiveRecord::Deadlocked if calls == 1

        original.call(**kwargs)
      end

      expect do
        described_class.perform_now(run_id: run.id)
      end.to have_enqueued_job(described_class).with(run_id: run.id)
      expect(run.reload).to be_active
      expect(receipt.reload.receipt_items).to be_empty

      perform_enqueued_jobs(only: described_class)
      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(receipt.reload.receipt_items.count).to eq(1)
        expect(receipt.receipt_items.sole.pricing_source_kind).to eq('reference_quantity_price')
        expect(run.reload.status).to eq('succeeded')
        expect(run.metadata).to have_key('reference_pricing_auto_adoption_claim')
        expect(calls).to eq(2)
        expect(enqueued_finalize_jobs).to be_empty
      end
    end

    it 'transient DB retryを3回使い切るとsafe errorでterminal化して元例外を再送出する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      error = Receipts::Processing::RetryableFinalizeError.new('transient_finalize_database_error')
      allow(Receipts::Processing).to receive(:run_finalize).with(run).and_raise(error)
      job = described_class.new(run_id: run.id)
      job.executions = 2
      job.exception_executions = {
        described_class::RETRYABLE_ERRORS.to_s => 2
      }

      expect { job.perform_now }.to raise_error(error)

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.error_code).to eq('unexpected_error')
        expect(run.error_message).to be_nil
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_message.to_s).not_to include('transient_finalize_database_error')
      end
    end

    it 'retry枯渇後のterminal化もDB競合した場合は成功扱いせず再送出する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      finalize_error = Receipts::Processing::RetryableFinalizeError.new(
        'transient_finalize_database_error'
      )
      terminal_error = ActiveRecord::LockWaitTimeout.new('private terminal detail')
      allow(Receipts::Processing).to receive(:run_finalize).with(run).and_raise(finalize_error)
      allow(Receipts::Processing).to receive(:fail).with(
        run,
        error_stage: 'finalize',
        error_code: 'unexpected_error',
        error_message: nil
      ).and_raise(terminal_error)
      job = described_class.new(run_id: run.id)
      job.executions = 2
      job.exception_executions = {
        described_class::RETRYABLE_ERRORS.to_s => 2
      }

      expect { job.perform_now }.to raise_error(terminal_error)

      aggregate_failures do
        expect(run.reload).to be_active
        expect(receipt.reload.status).to eq('processing')
      end
    end

    it 'finalize中に負値itemが混じっても通常明細として保存せず失敗にしない' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ocr_result = {
        success: true,
        lines: [ 'Short Dated Stock -2160', '合計 0' ],
        candidates: {
          store_name: 'テストストア',
          total_amount: 0,
          country_region: 'JPN',
          payment_method_text: '現金',
          items: [ { raw_text: 'Short Dated Stock', line_total: -2160 } ],
          payments: [ { method: 'Cash', amount: 0 } ],
          tax_details: []
        }
      }
      ai_result = {
        success: true,
        needs_review: false,
        receipt_attributes: { payment_method: 'cash' },
        receipt_items_attributes: [
          { index: 0, suggested_name: 'Short Dated Stock', category: 'other', needs_review: false }
        ]
      }
      decision = Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'ai_success',
        ocr_result: ocr_result,
        ai_result: ai_result
      )

      Receipts::Processing.record_ocr_snapshot(run, ocr_result)
      Receipts::Processing.record_ai_normalized_result(run, ai_result)
      Receipts::Processing.record_finalize_decision(run, decision)
      allow(ReceiptAmountService).to receive(:call).and_return(
        {
          resolved: { total: 0, subtotal: 0, tax: 0, tax_rate: nil },
          computed: {
            items: [
              { price: -2160, quantity: 1, line_total: -2160 }
            ]
          },
          tax_details: [],
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: [],
          mismatch_codes: [],
          blocking_mismatch_codes: [],
          warning_mismatch_codes: [],
          warning_reasons: [],
          mismatch_messages: [],
          needs_review: false
        }
      )

      expect { described_class.perform_now(run_id: run.id) }.not_to raise_error

      aggregate_failures do
        expect(run.reload.status).to eq('succeeded')
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.receipt_items).to be_empty
        expect(receipt.review_reasons).to include('adjustment_uncertain')
        expect(receipt.processing_error_code).to be_nil
      end
    end
  end
end
