module Analysis
  class RetryService
    SOURCE = "admin_retry".freeze
    RETRY_TYPES = %w[
      full_reanalyze
      ocr_retry
      ai_retry
      finalize_retry
    ].freeze

    Result = Struct.new(:run, :enqueued_job, :retry_type, :error_code, :error_message, keyword_init: true) do
      def success?
        error_code.blank?
      end

      def failure?
        !success?
      end
    end

    class << self
      def call(receipt:, parent_run: nil, actor:, retry_type:, reason: nil)
        new(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: retry_type,
          reason: reason
        ).call
      end
    end

    def initialize(receipt:, parent_run:, actor:, retry_type:, reason:)
      @receipt = receipt
      @parent_run = parent_run
      @actor = actor
      @retry_type = retry_type.to_s
      @reason = reason
    end

    def call
      return failure(:invalid_retry_type, "Unknown retry_type=#{retry_type}") unless RETRY_TYPES.include?(retry_type)
      return failure(:actor_required, "actor is required") unless actor
      return failure(:parent_run_required, "parent_run is required") if parent_run_required? && parent_run.blank?
      return failure(:snapshot_missing, missing_snapshot_message) unless required_snapshots_present?

      result = nil

      ReceiptAnalysisRun.transaction do
        start_result = ReceiptAnalysisRuns.start(
          receipt: receipt,
          source: SOURCE,
          requested_by_user: actor,
          request_reason: reason,
          parent_run: parent_run
        )

        unless start_result.created?
          result = failure(:active_run_exists, "receipt already has an active analysis run", run: start_result.run)
          raise ActiveRecord::Rollback
        end

        run = start_result.run
        copy_retry_snapshots(run)
        mark_receipt_processing!

        result = Result.new(run: run, enqueued_job: job_class, retry_type: retry_type)
      end

      return result if result.failure?

      result.enqueued_job.perform_later(run_id: result.run.id)
      result
    end

    private

    attr_reader :receipt, :parent_run, :actor, :retry_type, :reason

    def parent_run_required?
      retry_type.in?(%w[ai_retry finalize_retry])
    end

    def required_snapshots_present?
      case retry_type
      when "ai_retry"
        parent_run&.ocr_result_snapshot.present?
      when "finalize_retry"
        parent_run&.ocr_result_snapshot.present? &&
          parent_run&.ai_normalized_result_snapshot.present? &&
          parent_finalize_decision.present?
      else
        true
      end
    end

    def missing_snapshot_message
      case retry_type
      when "ai_retry"
        "parent_run.ocr_result_snapshot is required"
      when "finalize_retry"
        "parent_run ocr_result_snapshot, ai_normalized_result_snapshot, and finalize_decision are required"
      else
        "required retry snapshot is missing"
      end
    end

    def parent_finalize_decision
      @parent_finalize_decision ||= ReceiptAnalysisPipeline::FinalizeDecision.from_snapshot(
        parent_run&.metadata.to_h["finalize_decision"]
      )
    end

    def copy_retry_snapshots(run)
      case retry_type
      when "ai_retry"
        ReceiptAnalysisRuns.copy_retry_snapshots(run, parent_run: parent_run, include_ocr: true)
      when "finalize_retry"
        ReceiptAnalysisRuns.copy_retry_snapshots(
          run,
          parent_run: parent_run,
          include_ocr: true,
          include_ai: true,
          include_finalize_decision: true
        )
      end
    end

    def mark_receipt_processing!
      receipt.update!(
        status: "processing",
        processing_error_code: nil,
        processing_error_message: nil,
        review_reasons: []
      )
    end

    def job_class
      case retry_type
      when "full_reanalyze", "ocr_retry"
        ReceiptOcrJob
      when "ai_retry"
        ReceiptAiEnrichmentJob
      when "finalize_retry"
        ReceiptFinalizeJob
      end
    end

    def failure(error_code, error_message, run: nil)
      Result.new(
        run: run,
        enqueued_job: nil,
        retry_type: retry_type,
        error_code: error_code.to_s,
        error_message: error_message
      )
    end
  end
end
