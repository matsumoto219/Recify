require "rails_helper"

RSpec.describe LegalDocuments::Sync do
  before do
    LegalAcceptance.delete_all
    LegalDocument.delete_all
  end

  it "synchronizes YAML legal documents into the database idempotently" do
    expect do
      described_class.call
    end.to change(LegalDocument, :count).by(2)

    aggregate_failures do
      expect(LegalDocument.current.pluck(:document_type, :version, :locale)).to match_array(
        [
          [ "privacy", "2026-06-21", "ja" ],
          [ "terms", "2026-06-21", "ja" ]
        ]
      )
      expect(LegalDocuments::Verifier.verify_database!).to be(true)
    end

    expect do
      described_class.call
    end.not_to change(LegalDocument, :count)
  end

  it "fails when synchronized content changes after acceptance history exists" do
    described_class.call
    document = LegalDocument.current.find_by!(document_type: "terms")
    create(:legal_acceptance, legal_document: document)

    file_document = instance_double(
      LegalDocuments::FileDocument,
      identity: [ document.document_type, document.version, document.locale ],
      current_key: [ document.document_type, document.locale ],
      document_type: document.document_type,
      version: document.version,
      locale: document.locale,
      content_digest: "changed-digest",
      attributes_for_database: document.attributes.symbolize_keys.slice(
        :document_type,
        :version,
        :locale,
        :title,
        :source_path,
        :effective_on,
        :published_on,
        :last_updated_on,
        :reconsent_required,
        :current,
        :status,
        :content_digest
      ).merge(content_digest: "changed-digest")
    )
    repository = instance_double(
      LegalDocuments::Repository,
      verify_files!: true,
      all: [ file_document ],
      current_documents: [ file_document ],
      current_document?: true
    )

    expect do
      described_class.call(repository: repository)
    end.to raise_error(LegalDocuments::SyncError)
  end
end
