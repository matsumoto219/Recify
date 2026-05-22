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
      end
    end

    it 'locale経由の失敗flashでログイン画面へ戻す' do
      allow(User).to receive(:guest!).and_raise(StandardError, 'guest unavailable')

      post guest_sign_in_path

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:alert]).to eq(I18n.t('flash.guest_sessions.create.failure'))
      end
    end
  end
end
