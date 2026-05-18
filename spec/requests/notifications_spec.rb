require 'rails_helper'

RSpec.describe 'Notifications', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe 'header badge' do
    it '未読通知件数をheaderに表示する' do
      create_list(:notification, 2, user:, read_at: nil)
      create(:notification, :read, user:)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      badge = document.at_css('#notifications_unread_badge')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('a[aria-label="通知"]')).to be_present
        expect(badge).to be_present
        expect(badge.text).to include('2')
      end
    end
  end

  describe 'GET /notifications' do
    it '自分の通知だけを表示する' do
      create(:notification, user:, title: '自分の通知', body: '確認できます')
      create(:notification, user: create(:user), title: '他人の通知')

      get notifications_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('自分の通知')
        expect(response.body).to include('確認できます')
        expect(response.body).not_to include('他人の通知')
      end
    end
  end

  describe 'PATCH /notifications/:id/read' do
    it '通知を既読化してaction_pathへ遷移する' do
      receipt = create(:receipt, :completed, user:)
      notification = create(
        :notification,
        user:,
        notifiable: receipt,
        action_path: receipt_path(receipt),
        read_at: nil
      )

      patch read_notification_path(notification)

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(notification.reload).to be_read
      end
    end

    it '他人の通知は読めない' do
      notification = create(:notification, user: create(:user))

      patch read_notification_path(notification)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /notifications/read_all' do
    it '自分の未読通知だけを一括既読化する' do
      create_list(:notification, 2, user:, read_at: nil)
      other_notification = create(:notification, user: create(:user), read_at: nil)

      patch read_all_notifications_path

      aggregate_failures do
        expect(response).to redirect_to(notifications_path)
        expect(user.notifications.unread.count).to eq(0)
        expect(other_notification.reload).to be_unread
      end
    end
  end
end
