FactoryBot.define do
  factory :recovery_code do
    association :user
    sequence(:code_digest) { |n| TwoFactor::RecoveryCodes.digest("RECOVERY-CODE-#{n}") }
    used_at { nil }
  end
end
