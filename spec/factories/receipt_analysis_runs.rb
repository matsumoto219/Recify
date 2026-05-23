FactoryBot.define do
  factory :receipt_analysis_run do
    association :receipt
    source { "upload" }
    stage { "queued" }
    status { "queued" }
    requested_by_user { nil }
    request_reason { nil }
    attempt_number { 1 }
    parent_run { nil }
    ocr_provider { nil }
    ocr_model { nil }
    ai_provider { nil }
    ai_model { nil }
    ai_fallback_provider { nil }
    ai_fallback_used { false }
    ocr_latency_ms { nil }
    ai_latency_ms { nil }
    total_latency_ms { nil }
    error_stage { nil }
    error_code { nil }
    error_message { nil }
    ocr_summary { {} }
    ai_input_snapshot { {} }
    ai_result_summary { {} }
    final_result_summary { {} }
    metadata { {} }

    trait :running do
      status { "running" }
      stage { "ocr" }
    end

    trait :succeeded do
      status { "succeeded" }
      stage { "completed" }
    end

    trait :failed do
      status { "failed" }
      stage { "completed" }
      error_stage { "ai" }
      error_code { "ai_api_error" }
    end

    trait :skipped do
      status { "skipped" }
    end

    trait :superseded do
      status { "superseded" }
    end

    trait :admin_retry do
      source { "admin_retry" }
      association :requested_by_user, factory: :user
    end
  end
end
