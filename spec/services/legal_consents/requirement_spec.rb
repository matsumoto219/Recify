require 'rails_helper'

RSpec.describe LegalConsents::Requirement do
  before do
    LegalDocuments::Sync.call
  end

  def current_document(document_type)
    LegalDocument.current!(document_type, locale: :ja)
  end

  def record_acceptance(user, document_type)
    document = current_document(document_type)
    create(:legal_acceptance, user: user, legal_document: document, acceptance_context: "signup")
  end

  it 'current terms/privacyに同意済みなら再同意不要' do
    user = create(:user)
    record_acceptance(user, :terms)
    record_acceptance(user, :privacy)

    requirement = described_class.new(user: user, locale: :ja)

    aggregate_failures do
      expect(requirement).not_to be_required
      expect(requirement.missing_documents).to be_empty
    end
  end

  it 'termsだけ未同意なら再同意が必要' do
    user = create(:user)
    record_acceptance(user, :privacy)

    requirement = described_class.new(user: user, locale: :ja)

    aggregate_failures do
      expect(requirement).to be_required
      expect(requirement.missing_documents).to contain_exactly(current_document(:terms))
    end
  end

  it 'privacyだけ未同意なら再同意が必要' do
    user = create(:user)
    record_acceptance(user, :terms)

    requirement = described_class.new(user: user, locale: :ja)

    aggregate_failures do
      expect(requirement).to be_required
      expect(requirement.missing_documents).to contain_exactly(current_document(:privacy))
    end
  end

  it 'reconsent_required=falseのcurrent documentは未同意でも強制しない' do
    LegalDocument.current.update_all(reconsent_required: false)
    user = create(:user)

    requirement = described_class.new(user: user, locale: :ja)

    aggregate_failures do
      expect(requirement).not_to be_required
      expect(requirement.required_documents).to be_empty
    end
  end

  it 'guestユーザーは再同意対象外' do
    guest = User.guest!

    requirement = described_class.new(user: guest, locale: :ja)

    aggregate_failures do
      expect(requirement).not_to be_required
      expect(requirement.required_documents).to be_empty
    end
  end

  it 'current documentが存在しない場合は明確に失敗する' do
    LegalDocument.where(document_type: "terms", locale: "ja").delete_all
    user = create(:user)

    expect { described_class.new(user: user, locale: :ja).required? }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
