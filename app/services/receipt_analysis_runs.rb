module ReceiptAnalysisRuns
  Error = Class.new(StandardError)
  InvalidTransition = Class.new(Error)
  TerminalRunError = Class.new(Error)
  EnqueueError = Class.new(Error)

  StartResult = Struct.new(:run, :created, keyword_init: true) do
    def created?
      created == true
    end
  end

  STALE_ERROR_CODE = "analysis_stale_run".freeze
  STUCK_PROCESSING_TERMINAL_RUN_STATUSES = %w[
    succeeded
    failed
    canceled
    superseded
  ].freeze
  STUCK_PROCESSING_RECEIPT_MESSAGE_KEY = "receipts.processing_errors.unexpected_failure".freeze
  DEFAULT_RETENTION_CLEANUP_LIMIT = 1000

  class << self
    def start(receipt:, source:, requested_by_user: nil, request_reason: nil, parent_run: nil)
      Starter.call(
        receipt: receipt,
        source: source,
        requested_by_user: requested_by_user,
        request_reason: request_reason,
        parent_run: parent_run
      )
    end

    def enqueue(run, job_class:)
      Enqueuer.call(run, job_class: job_class)
    end

    def start_stage(run, stage, at: Time.current, provider: nil, model: nil)
      Tracker.new(run).start_stage(stage, at: at, provider: provider, model: model)
    end

    def claim_stage(run, stage, at: Time.current)
      Tracker.new(run).claim_stage(stage, at: at)
    end

    def external_service_runtime_config(run)
      RuntimeConfigSnapshot.fetch_or_record(run)
    end

    def finish_stage(run, stage, at: Time.current)
      Tracker.new(run).finish_stage(stage, at: at)
    end

    def record_ocr_result(run, ocr_result, latency_ms: nil, at: Time.current)
      Tracker.new(run).record_ocr_result(
        SnapshotBuilder.ocr_summary(ocr_result),
        latency_ms: latency_ms,
        at: at
      )
    end

    def record_ocr_snapshot(run, ocr_result, at: Time.current)
      Tracker.new(run).record_ocr_snapshot(
        SnapshotBuilder.ocr_result_snapshot(ocr_result),
        at: at
      )
    end

    def record_ocr_response_artifact(run, raw_response_body, provider:, model_id: nil, at: Time.current)
      OcrResponseArtifact.capture(
        run,
        raw_response_body,
        provider: provider,
        model_id: model_id,
        at: at
      )
    end

    def record_ai_input(run, ai_input, at: Time.current)
      Tracker.new(run).record_ai_input(
        SnapshotBuilder.ai_input_snapshot(ai_input),
        at: at
      )
    end

    def record_ai_result(run, ai_result, latency_ms: nil, at: Time.current)
      Tracker.new(run).record_ai_result(
        SnapshotBuilder.ai_result_summary(ai_result),
        latency_ms: latency_ms,
        at: at
      )
    end

    def record_ai_normalized_result(run, ai_result, at: Time.current)
      Tracker.new(run).record_ai_normalized_result(
        SnapshotBuilder.ai_normalized_result_snapshot(ai_result),
        at: at
      )
    end

    def record_finalize_decision(run, decision, at: Time.current)
      Tracker.new(run).record_finalize_decision(
        SnapshotBuilder.finalize_decision_snapshot(decision, at: at),
        at: at
      )
    end

    def record_build_params_snapshot(run, build_params, at: Time.current)
      Tracker.new(run).record_build_params_snapshot(
        SnapshotBuilder.build_params_snapshot(build_params),
        at: at
      )
    end

    def record_final_result(run, receipt: nil, receipt_attributes: nil, items_attributes: nil, payments_attributes: nil, tax_details_attributes: nil, adjustments_attributes: nil, amount_result: nil, at: Time.current)
      Tracker.new(run).record_final_result(
        SnapshotBuilder.final_result_summary(
          receipt: receipt,
          receipt_attributes: receipt_attributes,
          items_attributes: items_attributes,
          payments_attributes: payments_attributes,
          tax_details_attributes: tax_details_attributes,
          adjustments_attributes: adjustments_attributes,
          amount_result: amount_result
        ),
        at: at
      )
    end

    def copy_retry_snapshots(run, parent_run:, include_ocr: false, include_ai: false, include_finalize_decision: false)
      Tracker.new(run).copy_retry_snapshots(
        ocr_summary: include_ocr ? SnapshotBuilder.sanitized_stored_snapshot(parent_run.ocr_summary) : nil,
        ocr_result_snapshot: include_ocr ? SnapshotBuilder.ocr_result_snapshot(parent_run.ocr_result_snapshot) : nil,
        ai_result_summary: include_ai ? SnapshotBuilder.sanitized_stored_snapshot(parent_run.ai_result_summary) : nil,
        ai_normalized_result_snapshot: include_ai ? SnapshotBuilder.ai_normalized_result_snapshot(parent_run.ai_normalized_result_snapshot) : nil,
        finalize_decision_snapshot: include_finalize_decision ? sanitized_finalize_decision_snapshot(parent_run) : nil
      )
    end

    def succeed(run, at: Time.current)
      Tracker.new(run).succeed(at: at)
    end

    def fail(run, error_stage:, error_code:, error_message: nil, error_metadata: nil, at: Time.current)
      Tracker.new(run).fail(
        error_stage: error_stage,
        error_code: error_code,
        error_message: error_message,
        error_metadata: error_metadata,
        at: at
      )
    end

    def supersede(run, at: Time.current)
      Tracker.new(run).supersede(at: at)
    end

    def cancel(run, at: Time.current)
      Tracker.new(run).cancel(at: at)
    end

    def cleanup_stale(cutoff: 6.hours.ago, limit: 100, dry_run: true)
      cutoff = cutoff || 6.hours.ago
      limit = normalize_positive_integer(limit, 100)
      dry_run = normalize_boolean(dry_run)
      runs = stale_runs(cutoff:, limit:)
      stuck_processing_receipts = stuck_processing_receipts(cutoff:, limit:)
      records = runs.map { |run| cleanup_run_record(run) }
      stuck_processing_records = stuck_processing_receipts.map { |receipt| stuck_processing_receipt_record(receipt) }
      result = {
        dry_run: dry_run,
        cutoff: cutoff,
        limit: limit,
        stale_count: runs.size,
        failed_count: 0,
        canceled_count: 0,
        skipped_count: dry_run ? runs.size : 0,
        stuck_processing_count: stuck_processing_receipts.size,
        stuck_processing_failed_count: 0,
        stuck_processing_skipped_count: dry_run ? stuck_processing_receipts.size : 0,
        records: records,
        stuck_processing_records: stuck_processing_records,
        errors: []
      }

      return result if dry_run

      runs.each_with_index do |run, index|
        Tracker.new(run).mark_stale!(error_code: STALE_ERROR_CODE)
        run.reload
        records[index] = cleanup_run_record(run)

        if run.status == "failed"
          result[:failed_count] += 1
        elsif run.status == "canceled"
          result[:canceled_count] += 1
        end
      rescue StandardError => e
        result[:errors] << cleanup_error_record(run, e)
      end

      stuck_processing_receipts.each_with_index do |receipt, index|
        marked_failed = mark_stuck_processing_receipt_failed!(receipt)
        receipt.reload
        stuck_processing_records[index] = stuck_processing_receipt_record(receipt)
        result[:stuck_processing_failed_count] += 1 if marked_failed
      rescue StandardError => e
        result[:errors] << stuck_processing_cleanup_error_record(receipt, e)
      end

      result[:skipped_count] = 0
      result[:stuck_processing_skipped_count] = 0
      result
    end

    def cleanup_expired(cutoff: Time.current, limit: DEFAULT_RETENTION_CLEANUP_LIMIT, dry_run: true)
      cutoff ||= Time.current
      limit = normalize_positive_integer(limit, DEFAULT_RETENTION_CLEANUP_LIMIT)
      dry_run = normalize_boolean(dry_run)
      runs = expired_terminal_runs(cutoff:, limit:)
      records = runs.map { |run| expired_run_record(run) }
      artifact_result = cleanup_expired_ocr_response_artifacts(dry_run: dry_run)
      result = {
        dry_run: dry_run,
        cutoff: cutoff,
        limit: limit,
        expired_count: runs.size,
        deleted_count: 0,
        expired_artifact_count: artifact_result[:expired_artifact_count],
        purged_artifact_count: artifact_result[:purged_artifact_count],
        artifact_errors: artifact_result[:errors],
        records: records
      }

      return result if dry_run

      ids = records.map { |record| record[:id] }
      purge_ocr_response_artifacts_for_run_ids(ids)
      result[:deleted_count] = ReceiptAnalysisRun
        .where(id: ids)
        .where.not(status: ReceiptAnalysisRun::ACTIVE_STATUSES)
        .delete_all
      result
    end

    private

    def cleanup_expired_ocr_response_artifacts(dry_run:)
      retention_days = OcrResponseArtifact.retention_days
      artifact_cutoff = Time.current - retention_days.days
      OcrResponseArtifact.purge_expired(
        cutoff: artifact_cutoff,
        limit: DEFAULT_RETENTION_CLEANUP_LIMIT,
        dry_run: dry_run
      )
    end

    def purge_ocr_response_artifacts_for_run_ids(ids)
      return if ids.blank?

      ActiveStorage::Attachment
        .where(record_type: "ReceiptAnalysisRun", name: "ocr_response_artifact", record_id: ids)
        .includes(:blob)
        .find_each(&:purge)
    end

    def sanitized_finalize_decision_snapshot(parent_run)
      decision = ReceiptAnalysisPipeline.finalize_decision_from_snapshot(
        parent_run.metadata.to_h["finalize_decision"]
      )
      return {} unless decision

      SnapshotBuilder.finalize_decision_snapshot(decision)
    end

    def stale_runs(cutoff:, limit:)
      ReceiptAnalysisRun
        .includes(:receipt)
        .active
        .where(updated_at: ..cutoff)
        .order(:updated_at, :id)
        .limit(limit)
        .to_a
    end

    def stuck_processing_receipts(cutoff:, limit:)
      Receipt
        .includes(:receipt_analysis_runs)
        .where(status: "processing")
        .where(updated_at: ..cutoff)
        .where.not(id: ReceiptAnalysisRun.active.select(:receipt_id))
        .order(:updated_at, :id)
        .limit(limit)
        .to_a
        .select { |receipt| stuck_processing_receipt?(receipt) }
    end

    def stuck_processing_receipt?(receipt)
      latest_run = latest_analysis_run_for(receipt)

      latest_run.blank? || STUCK_PROCESSING_TERMINAL_RUN_STATUSES.include?(latest_run.status)
    end

    def latest_analysis_run_for(receipt)
      receipt.receipt_analysis_runs.max_by(&:created_at)
    end

    def mark_stuck_processing_receipt_failed!(receipt)
      receipt.with_lock do
        receipt.reload
        return false unless receipt.processing?
        return false if receipt.receipt_analysis_runs.active.exists?
        return false unless stuck_processing_receipt?(receipt)

        receipt.update!(
          status: "failed",
          processing_error_code: STALE_ERROR_CODE,
          processing_error_message: I18n.t(STUCK_PROCESSING_RECEIPT_MESSAGE_KEY),
          review_reasons: []
        )
        true
      end
    end

    def expired_terminal_runs(cutoff:, limit:)
      ReceiptAnalysisRun
        .where.not(status: ReceiptAnalysisRun::ACTIVE_STATUSES)
        .where(expires_at: ..cutoff)
        .order(:expires_at, :id)
        .limit(limit)
        .to_a
    end

    def cleanup_run_record(run)
      receipt = run.receipt

      {
        id: run.id,
        run_key: run.run_key,
        status: run.status,
        stage: run.stage,
        receipt_id: receipt.id,
        receipt_status: receipt.status,
        updated_at: run.updated_at
      }
    end

    def stuck_processing_receipt_record(receipt)
      latest_run = latest_analysis_run_for(receipt)

      {
        receipt_id: receipt.id,
        receipt_public_id: receipt.public_id,
        receipt_status: receipt.status,
        latest_run_key: latest_run&.run_key,
        latest_run_status: latest_run&.status,
        latest_run_stage: latest_run&.stage,
        updated_at: receipt.updated_at
      }
    end

    def expired_run_record(run)
      {
        id: run.id,
        run_key: run.run_key,
        status: run.status,
        stage: run.stage,
        expires_at: run.expires_at
      }
    end

    def cleanup_error_record(run, error)
      {
        id: run&.id,
        run_key: run&.run_key,
        error_class: error.class.name,
        error_message: error.message
      }
    end

    def stuck_processing_cleanup_error_record(receipt, error)
      {
        receipt_id: receipt&.id,
        receipt_public_id: receipt&.public_id,
        error_class: error.class.name,
        error_message: error.message
      }
    end

    def normalize_positive_integer(value, fallback)
      integer = value.to_i

      integer.positive? ? integer : fallback
    end

    def normalize_boolean(value)
      return true if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
