require 'rails_helper'

RSpec.describe Analysis::RetryService do
  include ActiveJob::TestHelper

  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:actor) { create(:user) }
  let(:receipt) do
    create(
      :receipt,
      :completed,
      :with_image,
      processing_error_code: 'ai_api_error',
      processing_error_message: 'AI failed',
      review_reasons: [ 'ai_fallback' ]
    )
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    ExternalServices.reset!
  end

  after do
    ExternalServices.reset!
  end

  describe '.call' do
    it 'full_reanalyzeでnew runを作り、ReceiptOcrJobをrun_idだけでenqueueする' do
      result = nil

      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: '問い合わせ対応',
          request: request_context,
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(result.retry_type).to eq('full_reanalyze')
        expect(result.enqueued_job).to eq(ReceiptOcrJob)
        expect(result.run).to be_persisted
        expect(result.run.source).to eq('admin_retry')
        expect(result.run.requested_by_user).to eq(actor)
        expect(result.run.request_reason).to eq('問い合わせ対応')
        expect(result.run.parent_run).to be_nil
        expect(result.run.stage).to eq('queued')
        expect(result.run.status).to eq('queued')
        expect(receipt.reload).to be_processing
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.review_reasons).to eq([])
        expect(ReceiptOcrJob).to have_been_enqueued.with(run_id: result.run.id)
        expect(enqueued_jobs.last[:args]).to eq([ { 'run_id' => result.run.id, '_aj_ruby2_keywords' => [ 'run_id' ] } ])
        expect(UsageCounter.find_by!(user: actor, key: 'retry_operations_per_day').used_count).to eq(1)
        expect(audit_log).to have_attributes(
          actor_user: actor,
          actor_kind: 'admin',
          action: 'receipt_analysis.full_reanalyze',
          target_type: 'Receipt',
          target_id: receipt.id,
          target_uid: receipt.public_id,
          reason: '問い合わせ対応',
          outcome: 'succeeded',
          request_id: 'retry-request-id',
          user_agent: 'RetryService Spec'
        )
        expect(audit_log.ip_address.to_s).to eq('203.0.113.22')
        expect(audit_log.metadata).to include(
          'retry_type' => 'full_reanalyze',
          'parent_run_key' => nil,
          'new_run_key' => result.run.run_key,
          'enqueued_job' => 'ReceiptOcrJob',
          'source' => 'admin_retry'
        )
        expect(audit_log.before_state).to include(
          'receipt_status' => 'completed'
        )
        expect(audit_log.after_state).to include(
          'receipt_status' => 'processing',
          'new_run_key' => result.run.run_key,
          'new_run_status' => 'queued',
          'enqueued_job' => 'ReceiptOcrJob'
        )
      end
    end

    it 'retry_operations_per_day上限到達時はrun作成をrollbackし、enqueueせず失敗auditを残す' do
      create(:usage_counter, user: actor, key: 'retry_operations_per_day', used_count: 20)
      run_count = ReceiptAnalysisRun.count

      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'cap reached retry',
          request: request_context,
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('usage_limit_exceeded')
        end
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(ReceiptAnalysisRun.count).to eq(run_count)
        expect(receipt.reload).to be_completed
        expect_no_analysis_job_enqueued
        expect(UsageCounter.find_by!(user: actor, key: 'retry_operations_per_day').used_count).to eq(20)
        expect(audit_log).to have_attributes(
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'failed',
          error_code: 'usage_limit_exceeded',
          reason: 'cap reached retry'
        )
        expect(audit_log.metadata).to include(
          'retry_type' => 'full_reanalyze',
          'failure_reason' => 'usage_limit_exceeded',
          'source' => 'admin_retry',
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(audit_log.attributes.to_json).not_to include('credential_id', 'public_key', 'challenge', 'raw_response', 'prompt')
      end
    end

    it 'ocr_retryでparent_runを紐づけ、ReceiptOcrJobをenqueueする' do
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :ocr_retry,
        reason: 'OCRだけ再実行',
        reauthentication: reauthentication_context,
        confirmation: retry_confirmation
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.run.parent_run).to eq(parent_run)
        expect(result.run.requested_by_user).to eq(actor)
        expect(result.run.request_reason).to eq('OCRだけ再実行')
        expect(ReceiptOcrJob).to have_been_enqueued.with(run_id: result.run.id)
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it 'OCR停止中はfull_reanalyzeをrun作成やcounter消費前に拒否する' do
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))

      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'OCR停止中の再解析',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('ocr_unavailable')
          expect(result.error_message).to eq('OCR service is unavailable')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(receipt.reload).to be_completed
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect(UsageCounter.where(user: actor, key: 'retry_operations_per_day')).to be_empty
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'failed',
          error_code: 'ocr_unavailable'
        )
      end
    end

    it 'StatusStoreでOCR down時もfull_reanalyzeをrun作成やcounter消費前に拒否する' do
      mark_service_down(:ocr, error_code: 'external_service_quota_exceeded')

      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'OCR down中の再解析',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('ocr_unavailable')
          expect(result.error_message).to eq('OCR service is unavailable')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(receipt.reload).to be_completed
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect(UsageCounter.where(user: actor, key: 'retry_operations_per_day')).to be_empty
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'failed',
          error_code: 'ocr_unavailable'
        )
      end
    end

    it 'reauthentication contextをaudit metadataに保存し、credential materialは保存しない' do
      reauthenticated_at = Time.current

      result = described_class.call(
        receipt: receipt,
        actor: actor,
        retry_type: :full_reanalyze,
        reason: 'fresh passkey retry',
        confirmation: retry_confirmation,
        reauthentication: {
          method: 'passkey',
          reauthenticated_at: reauthenticated_at,
          credential_id: 'credential-secret',
          public_key: 'public-key-secret',
          challenge: 'challenge-secret'
        }
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(audit_log.metadata).to include(
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.metadata.to_json).not_to include(
          'credential-secret',
          'public-key-secret',
          'challenge-secret'
        )
      end
    end

    it 'reauthentication nilを拒否し、enqueueしない' do
      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'missing reauth retry',
          confirmation: retry_confirmation,
          reauthentication: nil
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('reauthentication_required')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'failed',
          error_code: 'reauthentication_required'
        )
      end
    end

    it 'SystemSettingsの再認証windowを超過した再解析を拒否する' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(1))

      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'expired retry reauth',
          confirmation: retry_confirmation,
          reauthentication: reauthentication_context.merge(reauthenticated_at: 2.minutes.ago)
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('reauthentication_required')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'failed',
          error_code: 'reauthentication_required'
        )
      end
    end

    it 'SystemSettingsの再認証window内なら再解析を許可する' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(15))

      result = described_class.call(
        receipt: receipt,
        actor: actor,
        retry_type: :full_reanalyze,
        reason: 'fresh retry reauth',
        request: request_context,
        confirmation: retry_confirmation,
        reauthentication: reauthentication_context.merge(reauthenticated_at: 10.minutes.ago)
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.enqueued_job).to eq(ReceiptOcrJob)
        expect(ReceiptOcrJob).to have_been_enqueued.with(run_id: result.run.id)
        expect(AuditLog.last.metadata).to include('reauthenticated' => true)
      end
    end

    it 'reason blankを拒否し、enqueueしない' do
      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: ' ',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('reason_required')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect_no_analysis_job_enqueued
      end
    end

    it 'confirmation missingを拒否し、enqueueしない' do
      result = described_class.call(
        receipt: receipt,
        actor: actor,
        retry_type: :full_reanalyze,
        reason: 'missing confirmation retry',
        reauthentication: reauthentication_context,
        confirmation: nil
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('confirmation_required')
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect_no_analysis_job_enqueued
      end
    end

    it 'confirmation mismatchを拒否し、enqueueしない' do
      result = described_class.call(
        receipt: receipt,
        actor: actor,
        retry_type: :full_reanalyze,
        reason: 'wrong confirmation retry',
        reauthentication: reauthentication_context,
        confirmation: 'WRONG'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('confirmation_required')
        expect(ReceiptAnalysisRun.where(receipt: receipt)).to be_empty
        expect_no_analysis_job_enqueued
      end
    end

    it 'ai_retryでOCR snapshotをコピーし、ReceiptAiEnrichmentJobをenqueueする' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_summary: parent_ocr_summary,
        ocr_result_snapshot: parent_ocr_snapshot
      )
      original_parent_state = parent_state(parent_run)

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :ai_retry,
        reason: 'AIだけ再実行',
        reauthentication: reauthentication_context,
        confirmation: retry_confirmation
      )

      run = result.run.reload

      aggregate_failures do
        expect(result).to be_success
        expect(run.parent_run).to eq(parent_run)
        expect(run.ocr_summary).to include(
          'schema_version' => 'receipt_analysis_run_ocr_summary_v1',
          'success' => true,
          'item_count' => 1
        )
        expect(run.ocr_summary).not_to have_key('raw_response')
        expect(run.ocr_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ocr_result_v1',
          'success' => true,
          'lines' => [ 'スマイル', '合計 2998' ]
        )
        expect(run.ocr_result_snapshot.dig('candidates', 'items').first).to include('raw_text' => 'アメリカ産米')
        expect(snapshot_json(run)).not_to include('full raw OCR text')
        expect(snapshot_json(run)).not_to include('provider raw')
        expect(snapshot_json(run)).not_to include('secret-token')
        expect(ReceiptAiEnrichmentJob).to have_been_enqueued.with(run_id: run.id)
        expect(ReceiptOcrJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
        expect(parent_state(parent_run.reload)).to eq(original_parent_state)
        expect(AuditLog.last.metadata).to include(
          'retry_type' => 'ai_retry',
          'parent_run_key' => parent_run.run_key,
          'new_run_key' => run.run_key,
          'enqueued_job' => 'ReceiptAiEnrichmentJob'
        )
        expect(AuditLog.last.metadata.to_json).not_to include('full raw OCR text', 'provider raw', 'secret-token')
      end
    end

    it 'AI停止中はai_retryをrun作成やcounter消費前に拒否する' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot
      )
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: :ai_retry,
          reason: 'AI停止中の再解析',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('ai_unavailable')
          expect(result.error_message).to eq('AI service is unavailable')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(receipt.reload).to be_completed
        expect(ReceiptAnalysisRun.where(receipt: receipt).where.not(id: parent_run.id)).to be_empty
        expect(UsageCounter.where(user: actor, key: 'retry_operations_per_day')).to be_empty
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.ai_retry',
          outcome: 'failed',
          error_code: 'ai_unavailable'
        )
      end
    end

    it 'StatusStoreでAI down時もai_retryをrun作成やcounter消費前に拒否する' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot
      )
      mark_service_down(:ai, error_code: 'ai_rate_limited')

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: :ai_retry,
          reason: 'AI down中の再解析',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('ai_unavailable')
          expect(result.error_message).to eq('AI service is unavailable')
        end
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(receipt.reload).to be_completed
        expect(ReceiptAnalysisRun.where(receipt: receipt).where.not(id: parent_run.id)).to be_empty
        expect(UsageCounter.where(user: actor, key: 'retry_operations_per_day')).to be_empty
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.ai_retry',
          outcome: 'failed',
          error_code: 'ai_unavailable'
        )
      end
    end

    it 'finalize_retryでOCR/AI snapshotとfinalize_decisionをコピーし、ReceiptFinalizeJobをenqueueする' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_summary: parent_ocr_summary,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_result_summary: parent_ai_summary,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: {
          'kept' => 'existing-parent-metadata',
          'finalize_decision' => parent_finalize_decision_snapshot.merge(
            'prompt' => 'do-not-copy',
            'messages' => [ 'do-not-copy' ],
            'secret' => 'do-not-copy'
          )
        }
      )
      original_parent_state = parent_state(parent_run)

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :finalize_retry,
        reason: '保存だけ再実行',
        reauthentication: reauthentication_context,
        confirmation: retry_confirmation
      )

      run = result.run.reload

      aggregate_failures do
        expect(result).to be_success
        expect(run.ocr_result_snapshot).to include('schema_version' => 'receipt_analysis_run_ocr_result_v1')
        expect(run.ai_result_summary).to include('schema_version' => 'receipt_analysis_run_ai_result_v1')
        expect(run.ai_normalized_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ai_normalized_result_v1',
          'success' => true
        )
        expect(run.metadata.keys).to contain_exactly('finalize_decision')
        expect(run.metadata.dig('finalize_decision', 'strategy')).to eq('ai_success')
        expect(snapshot_json(run)).not_to include('full raw OCR text')
        expect(snapshot_json(run)).not_to include('do-not-copy')
        expect(snapshot_json(run)).not_to include('provider raw')
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
        expect(ReceiptOcrJob).not_to have_been_enqueued
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(parent_state(parent_run.reload)).to eq(original_parent_state)
        expect(AuditLog.last.metadata).to include(
          'retry_type' => 'finalize_retry',
          'parent_run_key' => parent_run.run_key,
          'new_run_key' => run.run_key,
          'enqueued_job' => 'ReceiptFinalizeJob'
        )
      end
    end

    it 'finalize_retryはocr_only strategyならAI snapshotなしでもenqueueする' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot(strategy: 'ocr_only') }
      )

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :finalize_retry,
        reason: 'OCR only finalize retry',
        reauthentication: reauthentication_context,
        confirmation: retry_confirmation
      )

      run = result.run.reload

      aggregate_failures do
        expect(result).to be_success
        expect(run.ocr_result_snapshot).to include('schema_version' => 'receipt_analysis_run_ocr_result_v1')
        expect(run.ai_normalized_result_snapshot).to eq({})
        expect(run.metadata.dig('finalize_decision', 'strategy')).to eq('ocr_only')
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
      end
    end

    it 'finalize_retryはfail_receipt strategyならOCR/AI snapshotなしでもenqueueする' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: {},
        ai_normalized_result_snapshot: {},
        metadata: {
          'finalize_decision' => parent_finalize_decision_snapshot(strategy: 'fail_receipt').merge(
            error_code: 'unsupported_country',
            receipt_attributes: { country_region: 'USA' }
          )
        }
      )

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :finalize_retry,
        reason: 'failure finalize retry',
        reauthentication: reauthentication_context,
        confirmation: retry_confirmation
      )

      run = result.run.reload

      aggregate_failures do
        expect(result).to be_success
        expect(run.ocr_result_snapshot).to eq({})
        expect(run.ai_normalized_result_snapshot).to eq({})
        expect(run.metadata.dig('finalize_decision', 'strategy')).to eq('fail_receipt')
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
      end
    end

    it 'active runがある場合は失敗し、enqueueしない' do
      active_run = create(:receipt_analysis_run, :running, receipt: receipt)

      result = nil

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: nil,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'active run retry',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('active_run_exists')
        expect(result.run).to eq(active_run)
        expect(ReceiptAnalysisRun.where(receipt: receipt).count).to eq(1)
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'failed',
          error_code: 'active_run_exists'
        )
        expect(AuditLog.last.metadata).to include(
          'retry_type' => 'full_reanalyze',
          'failure_reason' => 'active_run_exists',
          'source' => 'admin_retry'
        )
        expect(AuditLog.last.before_state).to include(
          'receipt_status' => 'completed',
          'active_run_key' => active_run.run_key
        )
        expect(AuditLog.last.after_state).to include(
          'receipt_status' => 'completed',
          'failure_reason' => 'active_run_exists'
        )
      end
    end

    it '失敗auditにもreauthentication contextを保存する' do
      active_run = create(:receipt_analysis_run, :running, receipt: receipt)
      reauthenticated_at = Time.current

      result = described_class.call(
        receipt: receipt,
        parent_run: nil,
        actor: actor,
        retry_type: :full_reanalyze,
        reason: 'failure with reauth',
        confirmation: retry_confirmation,
        reauthentication: {
          method: 'passkey',
          reauthenticated_at: reauthenticated_at,
          credential_id: 'credential-secret',
          public_key: 'public-key-secret',
          challenge: 'challenge-secret'
        }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.run).to eq(active_run)
        expect(AuditLog.last.metadata).to include(
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601,
          'failure_reason' => 'active_run_exists'
        )
        expect(AuditLog.last.metadata.to_json).not_to include(
          'credential-secret',
          'public-key-secret',
          'challenge-secret'
        )
      end
    end

    it 'ai_retryでOCR snapshotがない場合は失敗し、run作成もenqueueもしない' do
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: {})

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: :ai_retry,
          reason: 'missing OCR snapshot retry',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        expect(result).to be_failure
        expect(result.error_code).to eq('ocr_snapshot_missing')
      end.not_to change(ReceiptAnalysisRun, :count)

      expect_no_analysis_job_enqueued
      expect(AuditLog.last).to have_attributes(
        action: 'receipt_analysis.ai_retry',
        outcome: 'failed',
        error_code: 'ocr_snapshot_missing'
      )
      expect(AuditLog.last.metadata).to include(
        'retry_type' => 'ai_retry',
        'parent_run_key' => parent_run.run_key,
        'failure_reason' => 'ocr_snapshot_missing'
      )
    end

    it 'full_reanalyzeで画像がない場合は失敗し、run作成もenqueueもしない' do
      receipt_without_image = create(:receipt, :completed)

      expect do
        result = described_class.call(
          receipt: receipt_without_image,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'missing image retry',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        expect(result).to be_failure
        expect(result.error_code).to eq('image_missing')
      end.not_to change(ReceiptAnalysisRun, :count)

      expect_no_analysis_job_enqueued
    end

    it 'finalize_retryでfinalize_decisionがない場合は失敗し、run作成もenqueueもしない' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: {}
      )

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: :finalize_retry,
          reason: 'missing finalize decision retry',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )

        expect(result).to be_failure
        expect(result.error_code).to eq('finalize_decision_missing')
      end.not_to change(ReceiptAnalysisRun, :count)

      expect_no_analysis_job_enqueued
    end

    it 'finalize_retryでAI snapshotがない場合は失敗し、enqueueしない' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :finalize_retry,
        reason: 'missing AI snapshot retry',
        reauthentication: reauthentication_context,
        confirmation: retry_confirmation
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('ai_snapshot_missing')
        expect_no_analysis_job_enqueued
      end
    end

    it '未知のretry_typeは失敗し、enqueueしない' do
      result = nil

      expect do
        result = described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :unknown_retry,
          reason: 'unknown retry',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('invalid_retry_type')
        expect_no_analysis_job_enqueued
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis.unknown_retry',
          outcome: 'failed',
          error_code: 'invalid_retry_type'
        )
        expect(AuditLog.last.metadata).to include(
          'retry_type' => 'unknown_retry',
          'failure_reason' => 'invalid_retry_type'
        )
      end
    end

    it 'audit log作成に失敗した場合はrun作成とenqueueを行わない' do
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(ActiveRecord::RecordInvalid)
      run_count = ReceiptAnalysisRun.count

      expect do
        described_class.call(
          receipt: receipt,
          actor: actor,
          retry_type: :full_reanalyze,
          reason: 'audit failure retry',
          reauthentication: reauthentication_context,
          confirmation: retry_confirmation
        )
      end.to raise_error(ActiveRecord::RecordInvalid)

      aggregate_failures do
        expect(ReceiptAnalysisRun.count).to eq(run_count)
        expect(receipt.reload).to be_completed
        expect_no_analysis_job_enqueued
      end
    end
  end

  describe '.eligibility' do
    it 'enqueueもDB更新もせず、retry_optionsを返す' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )

      expect do
        result = described_class.eligibility(receipt: receipt, parent_run: parent_run)

        aggregate_failures do
          expect(result.retry_options).to eq(
            [
              { type: 'full_reanalyze', possible: true, disabled_reason: nil },
              { type: 'ocr_retry', possible: true, disabled_reason: nil },
              { type: 'ai_retry', possible: true, disabled_reason: nil },
              { type: 'finalize_retry', possible: true, disabled_reason: nil }
            ]
          )
          expect_no_analysis_job_enqueued
        end
      end.not_to change { parent_run.reload.attributes }

      expect(AuditLog.count).to eq(0)
    end

    it 'active runがある場合は全retry不可にする' do
      create(:receipt_analysis_run, :running, receipt: receipt)

      options = described_class.eligibility(receipt: receipt, parent_run: nil).retry_options

      aggregate_failures do
        expect(options.map { |option| option[:possible] }).to all(be(false))
        expect(options.map { |option| option[:disabled_reason] }).to all(eq('active_run_exists'))
      end
    end

    it 'active run lookupをretry typeごとに繰り返さない' do
      create(:receipt_analysis_run, :running, receipt: receipt)

      queries = count_sql_queries do
        described_class.eligibility(receipt: receipt, parent_run: nil)
      end
      active_run_queries = queries.select do |sql|
        sql.include?('"receipt_analysis_runs"') &&
          sql.include?('"status"') &&
          sql.include?('ORDER BY') &&
          sql.include?('LIMIT')
      end

      expect(active_run_queries.size).to eq(1)
    end

    it '画像がない場合はfull_reanalyze / ocr_retryを不可にする' do
      receipt_without_image = create(:receipt, :completed)

      options = options_by_type(described_class.eligibility(receipt: receipt_without_image, parent_run: nil))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: false, disabled_reason: 'image_missing')
        expect(options['ocr_retry']).to include(possible: false, disabled_reason: 'image_missing')
      end
    end

    it '画像purge済みの場合もfull_reanalyze / ocr_retryを不可にする' do
      purged_receipt = create(
        :receipt,
        :completed,
        keep_image: false,
        image_purged_at: 1.hour.ago,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )

      options = options_by_type(described_class.eligibility(receipt: purged_receipt, parent_run: nil))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: false, disabled_reason: 'image_missing')
        expect(options['ocr_retry']).to include(possible: false, disabled_reason: 'image_missing')
      end
    end

    it 'OCR停止中はfull_reanalyze / ocr_retryを不可にする' do
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: parent_ocr_snapshot)

      options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: parent_run))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: false, disabled_reason: 'ocr_unavailable')
        expect(options['ocr_retry']).to include(possible: false, disabled_reason: 'ocr_unavailable')
        expect(options['ai_retry']).to include(possible: true, disabled_reason: nil)
      end
    end

    it 'StatusStoreでOCR down時もfull_reanalyze / ocr_retryを不可にする' do
      mark_service_down(:ocr, error_code: 'external_service_quota_exceeded')
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: parent_ocr_snapshot)

      options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: parent_run))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: false, disabled_reason: 'ocr_unavailable')
        expect(options['ocr_retry']).to include(possible: false, disabled_reason: 'ocr_unavailable')
        expect(options['ai_retry']).to include(possible: true, disabled_reason: nil)
      end
    end

    it 'AI停止中はai_retryだけを不可にしfull_reanalyzeは許可する' do
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: parent_ocr_snapshot)

      options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: parent_run))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: true, disabled_reason: nil)
        expect(options['ocr_retry']).to include(possible: true, disabled_reason: nil)
        expect(options['ai_retry']).to include(possible: false, disabled_reason: 'ai_unavailable')
      end
    end

    it 'StatusStoreでAI down時もai_retryだけを不可にしfull_reanalyzeは許可する' do
      mark_service_down(:ai, error_code: 'ai_rate_limited')
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: parent_ocr_snapshot)

      options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: parent_run))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: true, disabled_reason: nil)
        expect(options['ocr_retry']).to include(possible: true, disabled_reason: nil)
        expect(options['ai_retry']).to include(possible: false, disabled_reason: 'ai_unavailable')
      end
    end

    it 'OCR snapshotがある場合だけai_retryを可能にする' do
      missing_snapshot_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: {})
      ready_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: parent_ocr_snapshot)

      missing_options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: missing_snapshot_run))
      ready_options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: ready_run))

      aggregate_failures do
        expect(missing_options['ai_retry']).to include(possible: false, disabled_reason: 'ocr_snapshot_missing')
        expect(ready_options['ai_retry']).to include(possible: true, disabled_reason: nil)
      end
    end

    it 'finalize_retryの不足snapshotごとにdisabled_reasonを返す' do
      no_ocr_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: {},
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )
      no_ai_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )
      no_decision_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: {}
      )
      ready_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )
      ocr_only_no_ai_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot(strategy: 'ocr_only') }
      )
      fail_receipt_no_snapshots_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: {},
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot(strategy: 'fail_receipt') }
      )

      aggregate_failures do
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: no_ocr_run))['finalize_retry']).to include(possible: false, disabled_reason: 'ocr_snapshot_missing')
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: no_ai_run))['finalize_retry']).to include(possible: false, disabled_reason: 'ai_snapshot_missing')
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: no_decision_run))['finalize_retry']).to include(possible: false, disabled_reason: 'finalize_decision_missing')
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: ready_run))['finalize_retry']).to include(possible: true, disabled_reason: nil)
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: ocr_only_no_ai_run))['finalize_retry']).to include(possible: true, disabled_reason: nil)
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: fail_receipt_no_snapshots_run))['finalize_retry']).to include(possible: true, disabled_reason: nil)
      end
    end
  end

  def parent_ocr_summary
    {
      schema_version: 'receipt_analysis_run_ocr_summary_v1',
      success: true,
      item_count: 1,
      raw_response: 'provider raw',
      secret: 'secret-token'
    }
  end

  def parent_ocr_snapshot
    {
      schema_version: 'receipt_analysis_run_ocr_result_v1',
      success: true,
      raw_text: 'full raw OCR text should not be copied',
      lines: [ 'スマイル', '合計 2998' ],
      candidates: {
        store_name: 'ドラッグストア スマイル',
        total_amount: 2998,
        items: [
          {
            raw_text: 'アメリカ産米',
            line_total: 2998,
            raw_response: 'provider raw'
          }
        ]
      },
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt',
        raw_response: 'provider raw',
        secret: 'secret-token'
      }
    }
  end

  def parent_ai_summary
    {
      schema_version: 'receipt_analysis_run_ai_result_v1',
      success: true,
      provider: 'openai',
      raw_response: 'provider raw',
      prompt: 'do-not-copy'
    }
  end

  def parent_ai_snapshot
    {
      schema_version: 'receipt_analysis_run_ai_normalized_result_v1',
      success: true,
      error_code: nil,
      needs_review: false,
      review_reasons: [],
      receipt_attributes: {
        store_name: 'ドラッグストア スマイル',
        total_amount: 2998,
        prompt: 'do-not-copy'
      },
      receipt_items_attributes: [
        {
          raw_text: 'アメリカ産米',
          line_total: 2998,
          messages: [ 'do-not-copy' ]
        }
      ],
      meta: {
        provider: 'openai',
        model: 'gpt-test',
        response_body: 'provider raw'
      }
    }
  end

  def parent_finalize_decision_snapshot(strategy: 'ai_success')
    {
      schema_version: 'receipt_analysis_run_finalize_decision_v1',
      strategy: strategy,
      receipt_attributes: {},
      metadata: { reason: 'manual retry' },
      recorded_at: Time.current.iso8601
    }
  end

  def snapshot_json(run)
    JSON.generate(
      {
        ocr_summary: run.ocr_summary,
        ocr_result_snapshot: run.ocr_result_snapshot,
        ai_result_summary: run.ai_result_summary,
        ai_normalized_result_snapshot: run.ai_normalized_result_snapshot,
        metadata: run.metadata
      }
    )
  end

  def parent_state(run)
    run.reload.attributes.slice(
      'status',
      'stage',
      'ocr_summary',
      'ocr_result_snapshot',
      'ai_result_summary',
      'ai_normalized_result_snapshot',
      'metadata'
    )
  end

  def expect_no_analysis_job_enqueued
    expect(ReceiptOcrJob).not_to have_been_enqueued
    expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
    expect(ReceiptFinalizeJob).not_to have_been_enqueued
  end

  def mark_service_down(service, error_code:)
    3.times do
      ExternalServices.mark_failure!(
        service,
        error_code: error_code,
        reason: error_code
      )
    end
  end

  def options_by_type(result)
    result.retry_options.index_by { |option| option[:type] }
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

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end
    queries
  end

  def request_context
    instance_double(
      ActionDispatch::Request,
      request_id: 'retry-request-id',
      remote_ip: '203.0.113.22',
      user_agent: 'RetryService Spec'
    )
  end

  def reauthentication_context
    {
      method: 'passkey',
      reauthenticated_at: Time.current
    }
  end

  def retry_confirmation
    Analysis::RetryService::CONFIRMATION_TEXT
  end
end
