FactoryBot.define do
  factory :receipt do
    association :user
    store_name { "テストストア" }
    purchased_at { Time.current }
    total_amount { 1000 }
    payment_method { "cash" }
    status { "uploaded" }

    trait :processing do
      status { "processing" }
    end

    trait :review_needed do
      status { "review_needed" }
    end

    trait :completed do
      status { "completed" }
    end

    trait :failed do
      status { "failed" }
      processing_error_code { "ocr_api_error" }
    end

    trait :with_image do
      after(:build) do |receipt|
        receipt.image.attach(
          io: File.open(Rails.root.join("spec/fixtures/files/receipt_sample.jpg")),
          filename: "receipt_sample.jpg",
          content_type: "image/jpeg"
        )
      end
    end
  end
end
