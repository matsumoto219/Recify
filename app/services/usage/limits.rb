module Usage::Limits
  ANALYSIS_ERROR_CODE = "usage_limit_exceeded".freeze

  class << self
    def consume_ocr_job!(user:)
      Usage::Counters.check_and_increment!(
        user: user,
        key: "ocr_jobs_per_day",
        amount: 1,
        limit: UserLimits.effective_limit(user: user, key: "ocr_jobs_per_day")
      )
    end

    def ensure_ocr_job_within_limit!(user:)
      Usage::Counters.ensure_within_limit!(
        user: user,
        key: "ocr_jobs_per_day",
        limit: UserLimits.effective_limit(user: user, key: "ocr_jobs_per_day")
      )
    end

    def consume_ai_job!(user:)
      Usage::Counters.check_and_increment!(
        user: user,
        key: "ai_jobs_per_day",
        amount: 1,
        limit: UserLimits.effective_limit(user: user, key: "ai_jobs_per_day")
      )
    end

    def mark_analysis_run_blocked!(run:, stage:)
      receipt = run.receipt
      if receipt.processing?
        receipt.update!(
          status: "failed",
          processing_error_code: ANALYSIS_ERROR_CODE,
          processing_error_message: ANALYSIS_ERROR_CODE,
          review_reasons: []
        )
      end

      ReceiptAnalysisRuns.fail(
        run,
        error_stage: stage.to_s,
        error_code: ANALYSIS_ERROR_CODE,
        error_message: ANALYSIS_ERROR_CODE
      )
    rescue ReceiptAnalysisRuns::TerminalRunError
      nil
    end
  end
end
