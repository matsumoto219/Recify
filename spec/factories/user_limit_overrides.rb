FactoryBot.define do
  factory :user_limit_override do
    association :user
    key { "receipt_uploads_per_day" }
    value { { "value" => 75 } }
    enabled { true }
  end
end
