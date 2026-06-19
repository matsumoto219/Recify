require 'rails_helper'

RSpec.describe 'User registrations', type: :request do
  def attach_avatar(user)
    user.avatar.attach(
      io: File.open(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
      filename: 'avatar.jpg',
      content_type: 'image/jpeg'
    )
  end

  def create_user_session_for(user)
    UserSession.create!(
      user: user,
      session_uid_digest: "digest-#{SecureRandom.hex(16)}",
      session_version: user.session_version,
      started_at: Time.current,
      last_seen_at: Time.current,
      ip_address: '203.0.113.10',
      user_agent: 'RSpec user session'
    )
  end

  describe 'DELETE /users' do
    it '本人退会でuser配下のデータをhard deleteし、外部run/audit参照はnullifyして残す' do
      user = create(:user, email: 'delete-me@example.com')
      attach_avatar(user)
      receipt = create(:receipt, :with_image, user: user)
      owned_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
      passkey = create(:passkey, user: user, credential_id: 'credential-secret', public_key: 'public-key-secret')
      user_session = create_user_session_for(user)
      user_notification = create(:notification, user: user)
      receipt_notification = create(:notification, user: user, notifiable: receipt)
      other_user = create(:user)
      external_receipt = create(:receipt, user: other_user)
      requested_run = create(:receipt_analysis_run, :admin_retry, receipt: external_receipt, requested_by_user: user)
      audit_log = create(:audit_log, actor_user: user, target_type: 'User', target_id: user.id, target_uid: "user:#{user.id}")
      encrypted_password = user.encrypted_password
      avatar_attachment_id = user.avatar.attachment.id
      receipt_image_attachment_id = receipt.image.attachment.id

      sign_in user

      delete user_registration_path,
             headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' }

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(User.where(id: user.id)).not_to exist
        expect(Receipt.where(id: receipt.id)).not_to exist
        expect(ReceiptAnalysisRun.where(id: owned_run.id)).not_to exist
        expect(Passkey.where(id: passkey.id)).not_to exist
        expect(UserSession.where(id: user_session.id)).not_to exist
        expect(Notification.where(id: user_notification.id)).not_to exist
        expect(Notification.where(id: receipt_notification.id)).not_to exist
        expect(requested_run.reload.requested_by_user_id).to be_nil
        expect(audit_log.reload.actor_user_id).to be_nil
        expect(audit_log.target_uid).to eq("user:#{user.id}")
        expect(ActiveStorage::Attachment.where(id: avatar_attachment_id)).not_to exist
        expect(ActiveStorage::Attachment.where(id: receipt_image_attachment_id)).not_to exist
        expect(response.body).not_to include(encrypted_password, passkey.credential_id, passkey.public_key, user_session.session_uid_digest)
      end
    end

    it '退会後のHomeに完了flashをtoastとして表示する' do
      user = create(:user)
      sign_in user

      delete user_registration_path,
             headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' }
      follow_redirect!

      document = Nokogiri::HTML(response.body)
      flash = document.at_css('#flash')
      notice_surface = flash&.at_css('[data-controller~="notice-surface"]')
      home_stylesheet = document.at_css("link[rel='stylesheet'][href^='/home_lp.css?v=']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(request.path).to eq(root_path)
        expect(flash).to be_present
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('devise.registrations.destroyed'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('true')
        expect(home_stylesheet).to be_present
        expect(home_stylesheet['data-turbo-track']).to eq('reload')
      end
    end

    it '退会後は同じ認証情報でログインできない' do
      user = create(:user, email: 'deleted-login@example.com', password: 'password', password_confirmation: 'password')

      sign_in user
      delete user_registration_path

      post user_session_path,
           params: { user: { email: 'deleted-login@example.com', password: 'password' } }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:user_session_version]).to be_blank
        expect(session[:user_session_uid]).to be_blank
      end
    end

    it '本人退会をUsers親入口経由で実行する' do
      user = create(:user)
      allow(Users).to receive(:delete_account).and_call_original

      sign_in user
      delete user_registration_path

      expect(Users).to have_received(:delete_account).with(
        user: user,
        actor: user,
        request: kind_of(ActionDispatch::Request),
        audit: false
      )
    end
  end
end
