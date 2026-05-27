module UsageLimits
  ANALYSIS_ERROR_CODE = "usage_limit_exceeded".freeze

  class LimitExceeded < StandardError
    attr_reader :key, :limit, :used, :requested

    def initialize(key:, limit:, used:, requested:)
      @key = key
      @limit = limit
      @used = used
      @requested = requested

      super("usage_limit_exceeded")
    end

    def details
      {
        key: key,
        limit: limit,
        used: used,
        requested: requested
      }
    end
  end

  class << self
    def consume_ocr_job!(user:)
      UsageCounters.check_and_increment!(
        user: user,
        key: "ocr_jobs_per_day",
        amount: 1,
        limit: UserLimits.effective_limit(user: user, key: "ocr_jobs_per_day")
      )
    end

    def ensure_ocr_job_within_limit!(user:)
      UsageCounters.ensure_within_limit!(
        user: user,
        key: "ocr_jobs_per_day",
        limit: UserLimits.effective_limit(user: user, key: "ocr_jobs_per_day")
      )
    end

    def consume_ai_job!(user:)
      UsageCounters.check_and_increment!(
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
