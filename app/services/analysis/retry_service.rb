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
    Eligibility = Struct.new(:retry_options, keyword_init: true)

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

      def eligibility(receipt:, parent_run:)
        Eligibility.new(
          retry_options: RETRY_TYPES.map do |type|
            new(
              receipt: receipt,
              parent_run: parent_run,
              actor: nil,
              retry_type: type,
              reason: nil
            ).retry_option
          end
        )
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

      if (disabled_reason = disabled_reason_for(retry_type))
        return failure(disabled_reason, disabled_message(disabled_reason), run: disabled_run_for(disabled_reason))
      end

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

    def retry_option
      disabled_reason = disabled_reason_for(retry_type)

      {
        type: retry_type,
        possible: disabled_reason.blank?,
        disabled_reason: disabled_reason
      }
    end

    private

    attr_reader :receipt, :parent_run, :actor, :retry_type, :reason

    def parent_finalize_decision
      @parent_finalize_decision ||= ReceiptAnalysisPipeline.finalize_decision_from_snapshot(
        parent_run&.metadata.to_h["finalize_decision"]
      )
    end

    def disabled_reason_for(type)
      return "active_run_exists" if active_run_exists?

      case type
      when "full_reanalyze", "ocr_retry"
        return "image_missing" unless receipt&.image&.attached?
      when "ai_retry"
        return "parent_run_missing" if parent_run.blank?
        return "ocr_snapshot_missing" if parent_run.ocr_result_snapshot.blank?
      when "finalize_retry"
        return "parent_run_missing" if parent_run.blank?
        return "ocr_snapshot_missing" if parent_run.ocr_result_snapshot.blank?
        return "ai_snapshot_missing" if parent_run.ai_normalized_result_snapshot.blank?
        return "finalize_decision_missing" if parent_finalize_decision.blank?
      end

      nil
    end

    def active_run_exists?
      active_run.present?
    end

    def active_run
      return unless receipt

      @active_run ||= receipt.receipt_analysis_runs.active.order(created_at: :desc).first
    end

    def disabled_run_for(disabled_reason)
      active_run if disabled_reason.to_s == "active_run_exists"
    end

    def disabled_message(disabled_reason)
      case disabled_reason.to_s
      when "active_run_exists"
        "receipt already has an active analysis run"
      when "image_missing"
        "receipt image is required"
      when "parent_run_missing"
        "parent_run is required"
      when "ocr_snapshot_missing"
        "parent_run.ocr_result_snapshot is required"
      when "ai_snapshot_missing"
        "parent_run.ai_normalized_result_snapshot is required"
      when "finalize_decision_missing"
        "parent_run.metadata.finalize_decision is required"
      else
        "retry is not available"
      end
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
