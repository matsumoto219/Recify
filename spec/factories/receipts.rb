FactoryBot.define do
  factory :receipt do
    user
    store_name { "テストストア" }
    purchased_at { Time.current }
    total_amount { 1000 }
    payment_method { "cash" }
    status { "processing" }
  end
end
