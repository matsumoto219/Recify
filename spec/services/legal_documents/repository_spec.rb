require "rails_helper"

RSpec.describe LegalDocuments::Repository do
  subject(:repository) { described_class.new }

  it "loads current legal document versions from YAML" do
    expect(repository.current!(document_type: :terms, locale: :ja).version).to eq("2026-06-24")
    expect(repository.current!(document_type: :privacy, locale: :ja).version).to eq("2026-06-24")
  end

  it "verifies the versioned YAML files" do
    expect(repository.verify_files!).to be(true)
  end

  it "calculates a stable digest without exposing body text" do
    document = repository.current!(document_type: :terms, locale: :ja)

    expect(document.content_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(document.content_digest).to eq(repository.current!(document_type: :terms, locale: :ja).content_digest)
  end
end
