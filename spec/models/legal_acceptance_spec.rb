require "rails_helper"

RSpec.describe LegalAcceptance, type: :model do
  it "is valid with a matching legal document snapshot" do
    acceptance = build(:legal_acceptance)

    expect(acceptance).to be_valid
  end

  it "validates acceptance context" do
    acceptance = build(:legal_acceptance, acceptance_context: "imported")

    expect(acceptance).not_to be_valid
    expect(acceptance.errors[:acceptance_context]).to be_present
  end

  it "validates denormalized document attributes" do
    acceptance = build(:legal_acceptance, document_type: "privacy")

    expect(acceptance).not_to be_valid
    expect(acceptance.errors[:document_type]).to be_present
  end

  it "limits user agent length" do
    acceptance = build(:legal_acceptance, user_agent: "a" * 513)

    expect(acceptance).not_to be_valid
    expect(acceptance.errors[:user_agent]).to be_present
  end

  it "validates user and legal document uniqueness" do
    existing = create(:legal_acceptance)
    duplicate = build(:legal_acceptance, user: existing.user, legal_document: existing.legal_document)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:legal_document_id]).to be_present
  end
end
