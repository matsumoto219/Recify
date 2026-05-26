FactoryBot.define do
  factory :passkey do
    association :user
    sequence(:credential_id) { |n| "credential-#{n}" }
    public_key { "public-key" }
    sign_count { 0 }
    label { "MacBook Touch ID" }
    transports { [ "internal" ] }
    backup_eligible { false }
    backed_up { false }
    last_used_at { nil }
  end
end
