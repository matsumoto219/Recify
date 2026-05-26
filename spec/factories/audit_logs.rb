FactoryBot.define do
  factory :audit_log do
    association :actor_user, factory: :user
    actor_kind { "admin" }
    action { "receipt_analysis.full_reanalyze" }
    target_type { "Receipt" }
    target_id { 1 }
    target_uid { "rcpt_test" }
    reason { "問い合わせ対応" }
    outcome { "succeeded" }
    error_code { nil }
    metadata { { "retry_type" => "full_reanalyze" } }
    before_state { { "status" => "failed" } }
    after_state { { "status" => "processing" } }
    request_id { "request-id-1" }
    ip_address { "203.0.113.10" }
    user_agent { "RSpec" }

    trait :system do
      actor_user { nil }
      actor_kind { "system" }
      action { "receipt_analysis.stale_cleanup" }
    end

    trait :failed do
      outcome { "failed" }
      error_code { "operation_failed" }
    end
  end
end
