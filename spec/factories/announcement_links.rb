FactoryBot.define do
  factory :announcement_link do
    association :announcement
    label { "詳細を見る" }
    url { "/contact" }
    position { 0 }
  end
end
