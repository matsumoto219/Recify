module Usage::Limits
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
  end
end
