require 'rails_helper'

RSpec.describe 'Legal consents', type: :request do
  before do
    LegalDocuments::Sync.call
  end

  def current_document(document_type)
    LegalDocument.current!(document_type, locale: :ja)
  end

  def accept_current_documents!(user, context: "signup")
    LegalAcceptances::Recorder.record_current_documents!(
      user: user,
      acceptance_context: context,
      request: nil,
      locale: :ja
    )
  end

  describe 'private領域の再同意ガード' do
    it '未同意のログイン済みユーザーを再同意画面へ誘導する' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      get receipts_path

      aggregate_failures do
        expect(response).to redirect_to(legal_consent_path)
        expect(flash[:warning]).to eq(I18n.t('legal_consents.flash.required'))
      end
    end

    it 'public/legalページは同意前でも表示できる' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      aggregate_failures do
        get terms_path
        expect(response).to have_http_status(:ok)

        get privacy_path
        expect(response).to have_http_status(:ok)

        get announcements_path
        expect(response).to have_http_status(:ok)
      end
    end

    it 'guestユーザーは再同意ガードの対象外' do
      guest = User.guest!
      sign_in guest

      get receipts_path

      expect(response).to have_http_status(:ok)
    end

    it 'adminユーザーも再同意対象にする' do
      admin = create(:user, :admin)
      sign_in_without_legal_acceptance admin

      get admin_root_path

      expect(response).to redirect_to(legal_consent_path)
    end

    it 'current法務文書が未同期の場合はprivate領域から案内画面へ誘導する' do
      user = create(:user)
      sign_in_without_legal_acceptance user
      LegalDocument.delete_all

      get receipts_path

      aggregate_failures do
        expect(response).to redirect_to(legal_consent_path)
        expect(flash[:alert]).to eq(I18n.t('flash.legal_documents.unavailable'))
      end
    end

    it 'current文書に同意済みならprivate領域を表示する' do
      user = create(:user)
      accept_current_documents!(user)
      sign_in user

      get receipts_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /legal/consent' do
    it '再同意画面にcurrent terms/privacyのバージョン情報とリンクを表示する' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      get legal_consent_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal_consents.show.title'))
        expect(response.body).to include(current_document(:terms).title)
        expect(response.body).to include(current_document(:terms).version)
        expect(response.body).to include(current_document(:privacy).title)
        expect(response.body).to include(current_document(:privacy).version)
        expect(document.at_css("a[href='#{terms_path}']")).to be_present
        expect(document.at_css("a[href='#{privacy_path}']")).to be_present
        expect(document.at_css("input[name='legal_agreement']")).to be_present
        expect(document.at_css("a[href='#{destroy_user_session_path}'][data-turbo-method='delete']")).to be_present
        expect(response.body).not_to match(/translation missing/i)
      end
    end

    it '同意済みなら安全な既定先へ戻す' do
      user = create(:user)
      accept_current_documents!(user)
      sign_in user

      get legal_consent_path

      expect(response).to redirect_to(receipts_path)
    end

    it 'current法務文書が未同期の場合は同意フォームを出さず案内を表示する' do
      user = create(:user)
      sign_in_without_legal_acceptance user
      LegalDocument.delete_all

      get legal_consent_path
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:service_unavailable)
        expect(response.body).to include(I18n.t('flash.legal_documents.unavailable'))
        expect(response.body).to include(I18n.t('legal_consents.show.unavailable_title'))
        expect(document.at_css("input[name='legal_agreement']")).to be_nil
      end
    end
  end

  describe 'POST /legal/consent' do
    it 'checkboxなしでは同意履歴を作らない' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      expect do
        post legal_consent_path, params: { legal_agreement: "0" }
      end.not_to change(LegalAcceptance, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('legal_consents.errors.agreement_required'))
      end
    end

    it 'current terms/privacyのLegalAcceptanceをreconsent contextで作成する' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      expect do
        post legal_consent_path,
             params: { legal_agreement: "1" },
             headers: {
               "HTTP_USER_AGENT" => "Legal QA Browser",
               "HTTP_X_REQUEST_ID" => "legal-consent-request-id"
             }
      end.to change(user.legal_acceptances, :count).by(2)

      acceptances = user.reload.legal_acceptances.index_by(&:document_type)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(acceptances.keys).to contain_exactly("terms", "privacy")
        expect(acceptances.fetch("terms")).to have_attributes(
          legal_document: current_document(:terms),
          version: current_document(:terms).version,
          locale: "ja",
          acceptance_context: "reconsent",
          user_agent: "Legal QA Browser"
        )
        expect(acceptances.fetch("privacy")).to have_attributes(
          legal_document: current_document(:privacy),
          version: current_document(:privacy).version,
          locale: "ja",
          acceptance_context: "reconsent",
          user_agent: "Legal QA Browser"
        )
        expect(acceptances.values).to all(have_attributes(accepted_at: be_present))
        expect(acceptances.values).to all(have_attributes(ip_address: be_present))
        expect(acceptances.values).to all(have_attributes(request_id: be_present))
      end
    end

    it '再同意後は保存したprivate return pathへ戻す' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      get settings_path
      expect(response).to redirect_to(legal_consent_path)

      post legal_consent_path, params: { legal_agreement: "1" }

      expect(response).to redirect_to(settings_path)
    end

    it 'return_toパラメータを信用せずopen redirectにしない' do
      user = create(:user)
      sign_in_without_legal_acceptance user

      post legal_consent_path,
           params: {
             legal_agreement: "1",
             return_to: "https://evil.example/"
           }

      expect(response).to redirect_to(receipts_path)
    end

    it '同意済みユーザーに重複したLegalAcceptanceを作らない' do
      user = create(:user)
      accept_current_documents!(user)
      sign_in user

      expect do
        post legal_consent_path, params: { legal_agreement: "1" }
      end.not_to change(LegalAcceptance, :count)

      expect(response).to redirect_to(receipts_path)
    end
  end
end
