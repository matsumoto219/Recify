require 'rails_helper'

RSpec.describe 'GuestSessions', type: :request do
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

      user = User.where(guest: true).order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(user).to be_confirmed
        expect(user.name).to be_blank
        expect(user.display_name).to eq(I18n.t('users.display.guest_name'))
        expect(user.display_email).to eq(I18n.t('users.display.email_unregistered'))
        expect(user.last_sign_in_at).to be_present
        expect(user.legal_acceptances).to be_empty
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
