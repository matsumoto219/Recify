FactoryBot.define do
  factory :announcement do
    title { "サービスからのお知らせ" }
    body { "Recifyからのお知らせ本文です。" }
    status { "draft" }
    kind { "general" }
    pinned { false }
    priority { 0 }

    trait :published do
      status { "published" }
      published_at { Time.current }
    end

    trait :archived do
      status { "archived" }
    end

    trait :scheduled do
      status { "published" }
      published_at { Time.current }
      starts_at { 1.day.from_now }
    end

    trait :expired do
      status { "published" }
      published_at { 2.days.ago }
      starts_at { 2.days.ago }
      ends_at { 1.day.ago }
    end
  end
end
