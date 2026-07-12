require 'rails_helper'

RSpec.describe LegalDocuments do
  describe '.current_status' do
    it 'delegates status lookup to the private query' do
      status = instance_double(LegalDocuments::CurrentStatus::Result)
      allow(LegalDocuments::CurrentStatus).to receive(:call).and_return(status)

      expect(described_class.current_status(locale: :ja)).to eq(status)
      expect(LegalDocuments::CurrentStatus).to have_received(:call).with(locale: :ja)
    end
  end

  describe '.synchronized_file_for!' do
    let(:legal_document) do
      instance_double(
        LegalDocument,
        document_type: 'terms',
        version: '2026-06-21',
        locale: 'ja',
        source_path: 'config/legal_documents/terms/2026-06-21.ja.yml',
        content_digest: 'digest'
      )
    end
    let(:repository) { instance_double(LegalDocuments::Repository) }

    before do
      allow(LegalDocuments::Repository).to receive(:new).and_return(repository)
    end

    it 'returns the matching file document' do
      file_document = instance_double(
        LegalDocuments::FileDocument,
        source_path: legal_document.source_path,
        content_digest: legal_document.content_digest
      )
      allow(repository).to receive(:find!).and_return(file_document)

      expect(described_class.synchronized_file_for!(legal_document: legal_document)).to eq(file_document)
      expect(repository).to have_received(:find!).with(
        document_type: 'terms',
        version: '2026-06-21',
        locale: 'ja'
      )
    end

    it 'preserves the existing validation error for a digest mismatch' do
      file_document = instance_double(
        LegalDocuments::FileDocument,
        source_path: legal_document.source_path,
        content_digest: 'stale'
      )
      allow(repository).to receive(:find!).and_return(file_document)

      expect do
        described_class.synchronized_file_for!(legal_document: legal_document)
      end.to raise_error(
        LegalDocuments::ValidationError,
        'Legal document config/legal_documents/terms/2026-06-21.ja.yml is not synchronized'
      )
    end
  end

  describe 'maintenance facade' do
    it 'delegates sync and verification without exposing implementation constants to callers' do
      allow(LegalDocuments::Sync).to receive(:call).and_return(:synced)
      allow(LegalDocuments::Verifier).to receive(:verify_files!).and_return(:files_verified)
      allow(LegalDocuments::Verifier).to receive(:verify_database!).and_return(:database_verified)

      aggregate_failures do
        expect(described_class.sync(dry_run: true)).to eq(:synced)
        expect(described_class.verify_files!).to eq(:files_verified)
        expect(described_class.verify_database!).to eq(:database_verified)
      end
    end
  end
end
