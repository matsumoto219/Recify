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
      Usage::Counters.check!(
        user: user,
        key: "ocr_jobs_per_day",
        amount: 1,
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

    def ensure_ai_job_within_limit!(user:)
      Usage::Counters.check!(
        user: user,
        key: "ai_jobs_per_day",
        amount: 1,
        limit: UserLimits.effective_limit(user: user, key: "ai_jobs_per_day")
      )
    end

    def mark_analysis_run_blocked!(run:, stage:)
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
