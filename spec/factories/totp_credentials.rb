FactoryBot.define do
  factory :totp_credential do
    association :user
    totp_secret { ROTP::Base32.random }
    confirmed_at { Time.current }
    last_used_at { nil }
    last_accepted_time_step { nil }
  end
end
