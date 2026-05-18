FactoryBot.define do
  factory :notification do
    association :user
    kind { "receipt_completed" }
    title { "レシート解析が完了しました" }
    body { "レシートを確認できます。" }
    action_path { "/receipts/1" }
    read_at { nil }
    metadata { {} }

    trait :read do
      read_at { Time.current }
    end
  end
end
