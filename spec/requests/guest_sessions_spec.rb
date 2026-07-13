require 'rails_helper'

RSpec.describe 'GuestSessions', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  describe 'POST /users/guest_sign_in' do
    it 'locale経由の成功flashでゲストログインする' do
      user = create(:user, guest: true)
      allow(User).to receive(:guest!).and_return(user)

      post guest_sign_in_path

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(flash[:notice]).to eq(I18n.t('flash.guest_sessions.create.success'))
      end
    end

    it 'confirmed済みのゲストユーザーを作成してログインする' do
      expect do
        post guest_sign_in_path
      end.to change(User.where(guest: true), :count).by(1)
        .and change(UserSession, :count).by(1)

      user = User.where(guest: true).order(:id).last
      user_session = UserSession.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(user).to be_confirmed
        expect(user.name).to be_blank
        expect(user.display_name).to eq(I18n.t('users.display.guest_name'))
        expect(user.display_email).to eq(I18n.t('users.display.email_unregistered'))
        expect(user.last_sign_in_at).to be_present
        expect(user.legal_acceptances).to be_empty
        expect(session[:user_session_version]).to eq(user.session_version)
        expect(session[:user_session_uid]).to be_present
        expect(user_session).to have_attributes(
          user_id: user.id,
          session_version: user.session_version,
          sign_in_method: 'guest'
        )
      end
    end

    it 'session追跡recordを保存できない場合はloginを成立させず新規guestを残さない' do
      allow(UserSessions).to receive(:record_sign_in!).and_raise(ActiveRecord::StatementInvalid, 'local tracking failure')

      expect do
        post guest_sign_in_path
      end.not_to change(User.where(guest: true), :count)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:alert]).to eq(I18n.t('flash.guest_sessions.create.failure'))
        expect(session[:user_session_version]).to be_blank
        expect(session[:user_session_uid]).to be_blank
        expect(session['warden.user.user.key']).to be_blank
      end
    end

    it 'ログイン済みuserからのguest login要求は現在sessionを置き換えず新規guestも作らない' do
      user = create(:user)
      sign_in user
      expect(BotProtection).not_to receive(:verify_turnstile)

      expect do
        post guest_sign_in_path
      end.not_to change(User.where(guest: true), :count)

      aggregate_failures do
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(receipts_path)
        expect(session.dig('warden.user.user.key', 0, 0)).to eq(user.id)
      end
    end

    it '保持期間を超えたguestでも現在sessionが利用中ならcleanupしない' do
      guest_id = nil

      travel_to(8.days.ago) do
        post guest_sign_in_path
        guest_id = User.where(guest: true).order(:id).last.id
      end

      get receipts_path
      result = GuestUserCleanupJob.perform_now

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(User.exists?(guest_id)).to be(true)
        expect(result).to eq(deleted_count: 0, failed_count: 0)
      end
    end

    it 'guest logoutで追跡sessionをsigned outにする' do
      post guest_sign_in_path
      guest = User.where(guest: true).order(:id).last
      tracked_session = guest.user_sessions.order(:id).last

      delete destroy_user_session_path

      aggregate_failures do
        expect(response).to have_http_status(:see_other)
        expect(tracked_session.reload.signed_out_at).to be_present
        expect(session[:user_session_uid]).to be_blank
        expect(session[:user_session_version]).to be_blank
      end
    end

    it 'login_restricted中はTurnstile検証前に拒否し、ゲストユーザーを作成しない' do
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      expect(BotProtection).not_to receive(:verify_turnstile)

      expect do
        post guest_sign_in_path
      end.not_to change(User.where(guest: true), :count)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:alert]).to eq(I18n.t('shared.maintenance_mode.body'))
      end
    end

    it 'locale経由の失敗flashでログイン画面へ戻す' do
      allow(User).to receive(:guest!).and_raise(StandardError, 'guest unavailable')
      expect(Rails.logger).to receive(:warn)
        .with("[GuestSessionsController] guest_session_create_failed error_class=StandardError")

      post guest_sign_in_path

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:alert]).to eq(I18n.t('flash.guest_sessions.create.failure'))
      end
    end

    it 'Turnstile有効時にtokenなしならゲストを作成せずログイン画面へ戻す' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_token_missing"))

      expect do
        post guest_sign_in_path
      end.not_to change(User.where(guest: true), :count)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:alert]).to eq(I18n.t('flash.bot_protection.verification_failed'))
      end
    end

    it 'Turnstile検証失敗時はゲストを作成しない' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_verification_failed"))

      expect do
        post guest_sign_in_path, params: { "cf-turnstile-response" => "invalid-token" }
      end.not_to change(User.where(guest: true), :count)

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'Turnstile検証成功時は既存guest login flowを維持する' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)

      expect do
        post guest_sign_in_path, params: { "cf-turnstile-response" => "valid-token" }
      end.to change(User.where(guest: true), :count).by(1)

      expect(response).to redirect_to(receipts_path)
    end
  end
end
