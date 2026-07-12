require 'rails_helper'

RSpec.describe Admin::LegalAcceptanceStatus do
  before do
    LegalDocuments::Sync.call
  end

  def current_document(document_type)
    LegalDocument.current!(document_type, locale: :ja)
  end

  def accept(user, document_type, legal_document: current_document(document_type), accepted_at: Time.current, context: "signup")
    create(
      :legal_acceptance,
      user: user,
      legal_document: legal_document,
      accepted_at: accepted_at,
      acceptance_context: context
    )
  end

  def record_for(result, document_type)
    result[:records].find { |record| record[:document_type] == document_type.to_s }
  end

  it 'current terms/privacyに同意済みなら現行版同意済みとして返す' do
    user = create(:user)
    accepted_at = Time.zone.local(2026, 6, 22, 10, 0, 0)
    accept(user, :terms, accepted_at: accepted_at, context: "signup")
    accept(user, :privacy, accepted_at: accepted_at, context: "signup")

    result = described_class.call(user_id: user.id, locale: :ja)
    terms = record_for(result, :terms)
    privacy = record_for(result, :privacy)

    aggregate_failures do
      expect(result[:reconsent_required]).to be(false)
      expect(terms).to include(
        status: "current_accepted",
        current_version: current_document(:terms).version,
        latest_accepted_version: current_document(:terms).version,
        latest_accepted_at: accepted_at,
        accepted_context: "signup",
        accepted_locale: "ja",
        current_version_accepted: true,
        reconsent_required: false,
        missing: false
      )
      expect(privacy[:status]).to eq("current_accepted")
      expect(privacy[:current_version_accepted]).to be(true)
    end
  end

  it 'termsだけ未同意ならtermsをmissingとして返す' do
    user = create(:user)
    accept(user, :privacy)

    result = described_class.call(user_id: user.id, locale: :ja)
    terms = record_for(result, :terms)
    privacy = record_for(result, :privacy)

    aggregate_failures do
      expect(result[:reconsent_required]).to be(true)
      expect(terms).to include(
        status: "missing",
        latest_accepted_version: nil,
        latest_accepted_at: nil,
        current_version_accepted: false,
        reconsent_required: true,
        missing: true
      )
      expect(privacy[:status]).to eq("current_accepted")
    end
  end

  it 'privacyだけ未同意ならprivacyをmissingとして返す' do
    user = create(:user)
    accept(user, :terms)

    result = described_class.call(user_id: user.id, locale: :ja)
    terms = record_for(result, :terms)
    privacy = record_for(result, :privacy)

    aggregate_failures do
      expect(result[:reconsent_required]).to be(true)
      expect(terms[:status]).to eq("current_accepted")
      expect(privacy).to include(
        status: "missing",
        current_version_accepted: false,
        reconsent_required: true,
        missing: true
      )
    end
  end

  it '過去versionのみ同意済みならoutdatedとして返す' do
    user = create(:user)
    old_terms = create(:legal_document, document_type: "terms", version: "2026-01-01", current: false)
    accept(user, :terms, legal_document: old_terms, accepted_at: Time.zone.local(2026, 1, 2, 9, 0, 0))

    result = described_class.call(user_id: user.id, locale: :ja)
    terms = record_for(result, :terms)

    aggregate_failures do
      expect(result[:reconsent_required]).to be(true)
      expect(terms).to include(
        status: "outdated",
        current_version: current_document(:terms).version,
        latest_accepted_version: "2026-01-01",
        current_version_accepted: false,
        reconsent_required: true,
        missing: false
      )
    end
  end

  it '同意履歴がない場合は両方missingとして返す' do
    user = create(:user)

    result = described_class.call(user_id: user.id, locale: :ja)

    aggregate_failures do
      expect(result[:reconsent_required]).to be(true)
      expect(record_for(result, :terms)[:status]).to eq("missing")
      expect(record_for(result, :privacy)[:status]).to eq("missing")
    end
  end

  it '管理画面向けにIPやuser agentなどの生ログを返さない' do
    user = create(:user)
    accept(user, :terms)

    result = described_class.call(user_id: user.id, locale: :ja)
    returned_keys = result[:records].flat_map(&:keys)

    aggregate_failures do
      expect(returned_keys).not_to include(:ip_address)
      expect(returned_keys).not_to include(:user_agent)
      expect(returned_keys).not_to include(:request_id)
    end
  end
end
