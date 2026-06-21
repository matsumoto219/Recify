FactoryBot.define do
  factory :legal_document do
    sequence(:version) { |n| (Date.new(2026, 6, 20) + n.days).iso8601 }
    document_type { "terms" }
    locale { "ja" }
    title { document_type == "terms" ? "利用規約" : "プライバシーポリシー" }
    source_path { "config/legal_documents/#{document_type}/#{version}.#{locale}.yml" }
    effective_on { Date.iso8601(version) }
    published_on { Date.iso8601(version) }
    last_updated_on { Date.iso8601(version) }
    reconsent_required { true }
    current { false }
    status { "published" }
    sequence(:content_digest) { |n| "legal-document-digest-#{n}" }

    trait :privacy do
      document_type { "privacy" }
    end

    trait :current do
      current { true }
    end
  end
end
