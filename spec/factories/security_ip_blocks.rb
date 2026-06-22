# frozen_string_literal: true

FactoryBot.define do
  factory :security_ip_block do
    ip_address { "8.8.8.8" }
    status { "active" }
    reason { "abuse mitigation" }
    expires_at { 1.day.from_now }
    created_by { association :user, :admin }
    source_security_event { nil }
    metadata { { "source" => "spec" } }

    trait :revoked do
      status { "revoked" }
      revoked_at { Time.current }
      revoked_by { association :user, :admin }
      revoked_reason { "false positive" }
    end
  end
end
