require "rails_helper"

RSpec.describe LegalDocuments::Verifier do
  it "fails database verification before sync" do
    expect do
      described_class.verify_database!
    end.to raise_error(LegalDocuments::ValidationError, /Missing DB legal document/)
  end

  it "passes database verification after sync" do
    LegalDocuments::Sync.call

    expect(described_class.verify_database!).to be(true)
  end
end
