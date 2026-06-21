require "rails_helper"

RSpec.describe LegalAcceptances::Recorder do
  before do
    LegalAcceptance.delete_all
    LegalDocument.delete_all
    LegalDocuments::Sync.call
  end

  let(:user) { create(:user) }
  let(:accepted_at) { Time.zone.parse("2026-06-22 10:30:00") }
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: "127.0.0.1",
      user_agent: "RSpec Legal Recorder",
      request_id: "request-id-123"
    )
  end

  it "records current terms and privacy acceptances" do
    expect do
      described_class.record_current_documents!(
        user: user,
        acceptance_context: "signup",
        request: request,
        accepted_at: accepted_at
      )
    end.to change(user.legal_acceptances, :count).by(2)

    acceptances = user.legal_acceptances.order(:document_type).to_a
    terms_document = LegalDocument.current!(:terms, locale: :ja)
    privacy_document = LegalDocument.current!(:privacy, locale: :ja)

    aggregate_failures do
      expect(acceptances.map(&:document_type)).to eq(%w[privacy terms])
      expect(acceptances.map(&:version)).to contain_exactly(terms_document.version, privacy_document.version)
      expect(acceptances.map(&:legal_document)).to contain_exactly(terms_document, privacy_document)
      expect(acceptances).to all(have_attributes(acceptance_context: "signup", accepted_at: accepted_at))
      expect(acceptances.map { |acceptance| acceptance.ip_address.to_s }).to all(eq("127.0.0.1"))
      expect(acceptances).to all(have_attributes(user_agent: "RSpec Legal Recorder"))
      expect(acceptances).to all(have_attributes(request_id: "request-id-123"))
    end
  end

  it "is idempotent for the same current document versions" do
    2.times do
      described_class.record_current_documents!(
        user: user,
        acceptance_context: "signup",
        request: request
      )
    end

    expect(user.legal_acceptances.count).to eq(2)
  end

  it "truncates request metadata to column limits" do
    long_request = instance_double(
      ActionDispatch::Request,
      remote_ip: "127.0.0.1",
      user_agent: "a" * 600,
      request_id: "b" * 160
    )

    described_class.record_current!(
      user: user,
      document_type: :terms,
      acceptance_context: "guest_conversion",
      request: long_request,
      accepted_at: accepted_at
    )

    acceptance = user.legal_acceptances.sole

    aggregate_failures do
      expect(acceptance.user_agent.length).to eq(512)
      expect(acceptance.request_id.length).to eq(128)
      expect(acceptance.acceptance_context).to eq("guest_conversion")
    end
  end

  it "fails clearly when the current legal document is missing" do
    LegalDocument.where(document_type: "terms", locale: "ja").delete_all

    expect do
      described_class.record_current!(
        user: user,
        document_type: :terms,
        acceptance_context: "signup",
        request: request
      )
    end.to raise_error(ActiveRecord::RecordNotFound)
  end
end
