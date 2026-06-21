require "rails_helper"

RSpec.describe LegalDocument, type: :model do
  before do
    LegalAcceptance.delete_all
    LegalDocument.delete_all
  end

  it "validates document type" do
    document = build(:legal_document, document_type: "notice")

    expect(document).not_to be_valid
    expect(document.errors[:document_type]).to be_present
  end

  it "validates status" do
    document = build(:legal_document, status: "removed")

    expect(document).not_to be_valid
    expect(document.errors[:status]).to be_present
  end

  it "requires current documents to be published" do
    document = build(:legal_document, :current, status: "draft")

    expect(document).not_to be_valid
    expect(document.errors[:current]).to be_present
  end

  it "finds the current published document" do
    document = create(:legal_document, :current, document_type: "terms", version: "2026-06-21")

    expect(described_class.current!(:terms, locale: :ja)).to eq(document)
  end

  it "validates document type, version, and locale uniqueness" do
    existing = create(:legal_document, document_type: "terms", version: "2026-06-21", locale: "ja")
    duplicate = build(:legal_document, document_type: existing.document_type, version: existing.version, locale: existing.locale)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:version]).to be_present
  end

  it "validates source path uniqueness" do
    existing = create(:legal_document)
    duplicate = build(:legal_document, source_path: existing.source_path)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:source_path]).to be_present
  end

  it "validates only one current document per type and locale" do
    create(:legal_document, :current, document_type: "terms", version: "2026-06-21", locale: "ja")
    duplicate_current = build(:legal_document, :current, document_type: "terms", version: "2026-07-01", locale: "ja")

    expect(duplicate_current).not_to be_valid
    expect(duplicate_current.errors[:current]).to be_present
  end
end
