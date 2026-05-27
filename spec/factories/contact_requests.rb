FactoryBot.define do
  factory :contact_request do
    association :user
    email { user&.email || "sender@example.com" }
    email_digest { ContactRequests.email_digest(email) }
    category { "other" }
    subject { "問い合わせ件名" }
    body { "問い合わせ本文です。" }
    status { "open" }
    source { user&.guest? ? "guest" : "authenticated" }
    ip_address { "203.0.113.10" }
    user_agent { "RSpec" }
    request_id { SecureRandom.uuid }
  end
end
