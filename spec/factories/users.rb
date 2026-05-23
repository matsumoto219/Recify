FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "test#{n}@example.com" }
    password { "password" }
    password_confirmation { "password" }

    transient do
      confirmed { true }
    end

    after(:build) do |user, evaluator|
      user.skip_confirmation! if evaluator.confirmed
    end

    trait :unconfirmed do
      confirmed { false }
    end

    trait :admin do
      admin { true }
    end
  end
end
