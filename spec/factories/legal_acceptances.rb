FactoryBot.define do
  factory :legal_acceptance do
    user
    legal_document
    document_type { legal_document.document_type }
    version { legal_document.version }
    locale { legal_document.locale }
    accepted_at { Time.current }
    acceptance_context { "signup" }
    ip_address { "127.0.0.1" }
    user_agent { "RSpec" }
    request_id { SecureRandom.uuid }
  end
end
