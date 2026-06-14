require 'rails_helper'

RSpec.describe 'Admin contact requests', type: :request do
  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  describe 'GET /admin/contact_requests' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_contact_requests_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).not_to include(I18n.t('admin.contact_requests.index.title'))
      end
    end

    it 'non-adminを拒否する' do
      sign_in create(:user)

      get admin_contact_requests_path

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(I18n.t('admin.contact_requests.index.title'))
    end

    it 'adminが一覧とnavigationを閲覧でき、返信先全文は表示しない' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, email: 'sender@example.com', sender_name: '送信 太郎', subject: '問い合わせ件名')
      sign_in admin

      get admin_contact_requests_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('admin.contact_requests.index.title'))
        expect(response.body).to include(I18n.t('admin.navigation.contact_requests'))
        expect(response.body).to include(contact_request.request_uid)
        expect(response.body).to include('送信 太郎')
        expect(response.body).to include('se***@example.com')
        expect(response.body).not_to include('sender@example.com')
      end
    end

    it '匿名化済み問い合わせを一覧で確認できる' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, status: 'resolved', handled_at: 181.days.ago)
      ContactRequests.anonymize(contact_request)
      sign_in admin

      get admin_contact_requests_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(contact_request.request_uid)
        expect(response.body).to include('匿名化済み')
        expect(response.body).to include('re***@example.invalid')
      end
    end

    it 'filterとpaginationを適用する' do
      admin = create(:user, :admin)
      target = create(:contact_request, status: 'open', category: 'security')
      other = create(:contact_request, status: 'closed', category: 'account')
      sign_in admin

      get admin_contact_requests_path(status: 'open', category: 'security', limit: 1)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(target.request_uid)
        expect(response.body).not_to include(other.request_uid)
        expect(response.body).to include(I18n.t('admin.contact_requests.index.results.next'))
      end
    end
  end

  describe 'GET /admin/contact_requests/:id' do
    it 'adminが詳細を閲覧できる' do
      admin = create(:user, :admin)
      user = create(:user)
      contact_request = create(
        :contact_request,
        user: user,
        email: 'sender@example.com',
        sender_name: '送信 太郎',
        body: '問い合わせ本文',
        request_id: 'req-contact-show'
      )
      sign_in admin

      get admin_contact_request_path(contact_request)

      document = Nokogiri::HTML(response.body)
      copy_sources = document.css('[data-controller="clipboard"] [data-clipboard-target="source"]').map { |node| node.text.strip }
      copy_labels = document.css('button[data-action="click->clipboard#copy"]').map { |node| node['aria-label'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(contact_request.request_uid)
        expect(response.body).to include('問い合わせ本文')
        expect(response.body).to include('送信 太郎')
        expect(response.body).to include('se***@example.com')
        expect(response.body).to include(contact_request.email_digest)
        expect(response.body).to include('grid min-w-0 max-w-full gap-4 text-sm md:grid-cols-2 lg:grid-cols-3')
        expect(response.body).to include('break-words font-mono text-xs token-text-base [overflow-wrap:anywhere]')
        expect(response.body).to include('min-w-0 max-w-full md:col-span-2 lg:col-span-3')
        expect(response.body).to include(admin_user_path(user))
        expect(response.body).not_to include('sender@example.com')
        expect(copy_sources).to include(contact_request.request_uid)
        expect(copy_sources).to include(contact_request.email_digest)
        expect(copy_sources).to include('req-contact-show')
        expect(copy_labels).to all(include('コピー'))
      end
    end

    it '匿名化済み問い合わせ詳細を閲覧できる' do
      admin = create(:user, :admin)
      contact_request = create(
        :contact_request,
        status: 'closed',
        handled_at: 181.days.ago,
        sender_name: '送信 太郎',
        email: 'sender@example.com',
        subject: '問い合わせ件名',
        body: '問い合わせ本文'
      )
      ContactRequests.anonymize(contact_request)
      sign_in admin

      get admin_contact_request_path(contact_request)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(contact_request.request_uid)
        expect(response.body).to include('匿名化済み')
        expect(response.body).to include('[redacted]')
        expect(response.body).to include('[redacted by retention policy]')
        expect(response.body).to include('re***@example.invalid')
        expect(response.body).to include(contact_request.email_digest)
        expect(response.body).not_to include('送信 太郎')
        expect(response.body).not_to include('sender@example.com')
        expect(response.body).not_to include('問い合わせ本文')
      end
    end
  end

  describe 'PATCH /admin/contact_requests/:id' do
    it 'statusを更新しAuditLogへ本文やemail全文を保存しない' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, email: 'sender@example.com', body: 'AuditLogへ入れない本文')
      sign_in admin

      expect {
        patch admin_contact_request_path(contact_request), params: { contact_request: { status: 'in_progress' } }
      }.to change(AuditLog, :count).by(1)

      contact_request.reload
      audit_log = AuditLog.last
      audit_json = audit_log.attributes.slice('metadata', 'before_state', 'after_state').to_json

      aggregate_failures do
        expect(response).to redirect_to(admin_contact_request_path(contact_request))
        expect(contact_request.status).to eq('in_progress')
        expect(contact_request.handled_by_user).to eq(admin)
        expect(audit_log.action).to eq('admin.contact_requests.status_update')
        expect(audit_log.target_uid).to eq(contact_request.request_uid)
        expect(audit_log.metadata).to include(
          'request_uid' => contact_request.request_uid,
          'old_status' => 'open',
          'new_status' => 'in_progress',
          'category' => contact_request.category,
          'user_id' => contact_request.user_id,
          'email_digest' => contact_request.email_digest
        )
        expect(audit_json).not_to include('AuditLogへ入れない本文')
        expect(audit_json).not_to include('sender@example.com')
      end
    end

    it 'invalid statusは拒否する' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, status: 'open')
      sign_in admin

      expect {
        patch admin_contact_request_path(contact_request), params: { contact_request: { status: 'deleted' } }
      }.not_to change(AuditLog, :count)

      expect(contact_request.reload.status).to eq('open')
      expect(flash[:alert]).to eq(I18n.t('admin.contact_requests.messages.status_update_failed'))
    end
  end

  it 'delete routeを持たない' do
    contact_request = create(:contact_request)

    expect {
      Rails.application.routes.recognize_path(admin_contact_request_path(contact_request), method: :delete)
    }.to raise_error(ActionController::RoutingError)
  end
end
