FactoryBot.define do
  factory :usage_counter do
    association :user
    key { "receipt_uploads_per_day" }
    period { "day" }
    period_start { Time.zone.today.beginning_of_day }
    used_count { 0 }
    used_bytes { 0 }
  end
end
