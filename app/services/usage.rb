module Usage
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
    def consume_receipt_upload!(user:)
      Usage::Counters.check_and_increment!(
        user: user,
        key: "receipt_uploads_per_day",
        amount: 1,
        limit: effective_limit(user: user, key: "receipt_uploads_per_day")
      )
    end

    def consume_manual_receipt!(user:)
      Usage::Counters.check_and_increment!(
        user: user,
        key: "manual_receipts_per_day",
        amount: 1,
        limit: effective_limit(user: user, key: "manual_receipts_per_day")
      )
    end

    def consume_batch_upload!(user:, amount:)
      Usage::Counters.check_and_increment!(
        user: user,
        key: "batch_files_per_day",
        amount: amount,
        limit: effective_limit(user: user, key: "batch_files_per_day")
      )
    end

    def consume_retry_operation!(user:)
      Usage::Counters.check_and_increment!(
        user: user,
        key: "retry_operations_per_day",
        amount: 1,
        limit: effective_limit(user: user, key: "retry_operations_per_day")
      )
    end

    def ensure_ocr_job_within_limit!(user:)
      Usage::Limits.ensure_ocr_job_within_limit!(user: user)
    end

    def consume_ocr_job!(user:)
      Usage::Limits.consume_ocr_job!(user: user)
    end

    def consume_ai_job!(user:)
      Usage::Limits.consume_ai_job!(user: user)
    end

    def mark_analysis_run_blocked!(run:, stage:)
      Usage::Limits.mark_analysis_run_blocked!(run: run, stage: stage)
    end

    def counter_summary_for(user:)
      Usage::Counters.summary_for(user: user)
    end

    def limit_summary_for(user:)
      UserLimits.summary_for(user: user)
    end

    def effective_limit(user:, key:)
      UserLimits.effective_limit(user: user, key: key)
    end
  end
end
