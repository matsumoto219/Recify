require 'rails_helper'

RSpec.describe LegalDocuments::CurrentStatus do
  describe '.call' do
    before do
      LegalDocuments::Sync.call
    end

    it 'current terms/privacy が揃っている場合はreadyを返す' do
      result = described_class.call(locale: :ja)
      terms = LegalDocument.current!(:terms, locale: :ja)
      privacy = LegalDocument.current!(:privacy, locale: :ja)

      aggregate_failures do
        expect(result).to be_ready
        expect(result.missing_types).to be_empty
        expect(result.documents['terms']).to include(
          document_type: 'terms',
          locale: 'ja',
          present: true,
          version: terms.version,
          status: terms.status,
          current: true
        )
        expect(result.documents['privacy']).to include(
          document_type: 'privacy',
          locale: 'ja',
          present: true,
          version: privacy.version,
          status: privacy.status,
          current: true
        )
      end
    end

    it 'current文書が欠けている場合はmissing typeを返し例外にしない' do
      LegalDocument.where(document_type: 'privacy').delete_all

      result = described_class.call(locale: :ja)

      aggregate_failures do
        expect(result).not_to be_ready
        expect(result.missing_types).to eq([ 'privacy' ])
        expect(result.documents['terms']).to include(present: true)
        expect(result.documents['privacy']).to include(
          document_type: 'privacy',
          locale: 'ja',
          present: false
        )
      end
    end

    it 'DB同期前の空状態でも安全にmissingを返す' do
      LegalDocument.delete_all

      result = described_class.call(locale: :ja)

      aggregate_failures do
        expect(result).not_to be_ready
        expect(result.missing_types).to contain_exactly('terms', 'privacy')
        expect(result.documents.values).to all(include(present: false))
      end
    end
  end
end
