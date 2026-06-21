require 'rails_helper'

RSpec.describe 'Notifications', type: :request do
  let(:user) { create(:user) }
  let(:missing_receipt_id) { Receipt.maximum(:id).to_i + 1000 }
  let(:missing_receipt_public_id) { 'rcpt_ABCDEFGHJKLMNPQR' }

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
        expect(document.at_css('[data-controller="notification-dropdown"]')).to be_present
        notification_button = document.at_css('button[aria-label="通知"][aria-haspopup="dialog"][aria-expanded="false"]')
        expect(notification_button).to be_present
        expect(notification_button['class']).to include('token-text-muted')
        expect(notification_button['class']).to include('notification-icon-hover')
        expect(document.at_css('header #notifications-dropdown')).to be_nil
        expect(badge).to be_present
        expect(badge.text).to include('2')
      end
    end

    it '通知dropdownに最新5件だけ表示し、通知一覧への導線を出す' do
      notifications = 6.times.map do |index|
        create(
          :notification,
          user:,
          title: "通知#{index + 1}",
          body: "本文#{index + 1}",
          created_at: index.minutes.ago
        )
      end

      get receipts_path

      document = Nokogiri::HTML(response.body)
      dropdown = document.at_css('#notifications-dropdown')
      surface = dropdown.at_css('[data-notification-dropdown-surface]')
      motion = dropdown.at_css('[data-notification-dropdown-motion]')
      titles = dropdown.css('[data-notification-dropdown-item-title]').map(&:text).map(&:strip)
      delete_forms = dropdown.css("form[action^='/notifications/'][method='post']")
      delete_button = delete_forms.first.at_css('button')
      first_item = delete_forms.first.parent
      first_read_link = dropdown.at_css("a[href='#{read_notification_path(notifications.first)}']")
      internal_id_path = "/notifications/#{notifications.first.id}"

      aggregate_failures do
        expect(dropdown).to be_present
        expect(dropdown.at_css('#notifications_dropdown_content')).to be_present
        expect(dropdown['class']).to include('hidden')
        expect(surface).to be_present
        expect(surface['class']).to include('notification-dropdown-motion')
        expect(motion).to be_present
        expect(motion['class']).to include('opacity-0')
        expect(motion['class']).to include('-translate-y-2')
        expect(motion['class']).to include('notification-dropdown-motion')
        expect(motion['class']).to include('transition-transform')
        expect(motion['class']).to include('transition-opacity')
        expect(dropdown.at_css('.notification-dropdown-panel')).to be_present
        expect(dropdown.at_css('a[href="/notifications"]')).to have_attributes(text: include(I18n.t('notifications.dropdown.view_all')))
        expect(dropdown.at_css(%([aria-label="#{I18n.t('shared.notifications.unread_aria')}"]))).to be_present
        expect(titles).to eq([ '通知1', '通知2', '通知3', '通知4', '通知5' ])
        expect(titles).not_to include('通知6')
        expect(read_notification_path(notifications.first)).to eq("/notifications/#{notifications.first.uid}/read")
        expect(notification_path(notifications.first)).to eq("/notifications/#{notifications.first.uid}")
        expect(first_read_link).to be_present
        expect(first_read_link['data-turbo-method']).to eq('patch')
        expect(dropdown.at_css(%(a[href="#{notifications.first.action_path}"]))).to be_nil
        expect(dropdown.to_html).not_to include("#{internal_id_path}/read")
        expect(dropdown.to_html).not_to include(internal_id_path)
        expect(delete_forms.size).to eq(5)
        expect(delete_forms.first['class']).to include('contents')
        expect(delete_forms.first.at_css('input[name="_method"]')['value']).to eq('delete')
        expect(first_item['class']).to include('token-hover-bg-card-subtle')
        expect(first_item.css('a form')).to be_empty
        expect(delete_forms.first.ancestors('a')).to be_empty
        expect(dropdown.css('a.token-hover-bg-card-subtle')).to be_empty
        expect(delete_button.text).to include('close')
        expect(delete_button['data-turbo-confirm']).to eq(I18n.t('notifications.item.delete_confirm'))
        expect(delete_button['data-confirm-variant']).to eq('danger')
        expect(delete_button['data-confirm-icon']).to eq('delete')
        expect(delete_button['data-confirm-confirm-label']).to eq(I18n.t('notifications.item.delete'))
        expect(delete_button['data-confirm-title']).to eq(I18n.t('notifications.item.delete_confirm_title'))
        expect(delete_button['data-confirm-backdrop']).to eq('plain')
        expect(delete_button['aria-label']).to eq(I18n.t('notifications.item.delete_aria', title: '通知1'))
        expect(delete_button['title']).to eq(I18n.t('notifications.item.delete_aria', title: '通知1'))
      end
    end

    it '通知保持件数設定を変更してもdropdownは最新5件だけ表示し未読件数を維持する' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      insert_notifications_for(user, count: 6)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      dropdown = document.at_css('#notifications-dropdown')
      badge = document.at_css('#notifications_unread_badge')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(dropdown.css('[data-notification-dropdown-item-title]').size).to eq(Notification::DROPDOWN_LIMIT)
        expect(badge.text).to include('6')
      end
    end

    it '削除確認設定がOFFならdropdownの通知削除confirmを出さない' do
      user.update!(delete_confirmation_enabled: false)
      notification = create(:notification, user:, title: '通知1')

      get receipts_path

      document = Nokogiri::HTML(response.body)
      dropdown = document.at_css('#notifications-dropdown')
      delete_form = dropdown.at_css("form[action='#{notification_path(notification)}'][method='post']")
      delete_button = delete_form.at_css('button')

      expect(delete_button['data-turbo-confirm']).to be_nil
    end

    it '削除済みreceiptの通知はdropdownに削除済みreceipt pathを出さない' do
      notification = create(
        :notification,
        user:,
        title: '削除済みレシート通知',
        notifiable_type: 'Receipt',
        notifiable_id: missing_receipt_id,
        action_path: receipt_path(missing_receipt_public_id)
      )

      get receipts_path

      document = Nokogiri::HTML(response.body)
      dropdown = document.at_css('#notifications-dropdown')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(dropdown).to be_present
        expect(dropdown.at_css(%(a[href="#{receipt_path(missing_receipt_public_id)}"]))).to be_nil
        expect(dropdown.at_css(%(a[href="#{read_notification_path(notification)}"][data-turbo-method="patch"]))).to be_present
        expect(dropdown.text).to include(I18n.t('notifications.item.deleted_target'))
      end
    end

    it '通知がない場合はdropdownにempty stateを表示する' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      dropdown = document.at_css('#notifications-dropdown')

      aggregate_failures do
        expect(dropdown).to be_present
        expect(dropdown.at_css('#notifications_dropdown_content')).to be_present
        expect(dropdown.text).to include(I18n.t('notifications.empty.title'))
        expect(dropdown.at_css('a[href="/notifications"]')).to have_attributes(text: include(I18n.t('notifications.dropdown.view_all')))
      end
    end
  end

  describe 'GET /notifications' do
    it '通知がない場合は統一されたempty stateを表示する' do
      get notifications_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#notifications_index_header')).to be_present
        expect(document.at_css('#notifications_list')).to be_present
        expect(response.body).to include(I18n.t('notifications.empty.title'))
        expect(response.body).to include(I18n.t('notifications.empty.description'))
      end
    end

    it '自分の通知だけを表示する' do
      notification = create(:notification, user:, title: '自分の通知', body: '確認できます')
      create(:notification, user: create(:user), title: '他人の通知')

      get notifications_path
      document = Nokogiri::HTML(response.body)
      notification_item = document.at_css("#notification_#{notification.id}")
      delete_form = notification_item.at_css("form[action='#{notification_path(notification)}'][method='post']")
      delete_button = delete_form.at_css('button')
      internal_id_path = "/notifications/#{notification.id}"

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#notifications_index_header')).to be_present
        expect(document.at_css('#notifications_list')).to be_present
        expect(response.body).to include('自分の通知')
        expect(response.body).to include('確認できます')
        expect(response.body).not_to include('他人の通知')
        expect(notification_path(notification)).to eq("/notifications/#{notification.uid}")
        expect(response.body).not_to include("#{internal_id_path}/read")
        expect(response.body).not_to include(%(action="#{internal_id_path}"))
        expect(notification_item['data-controller'].to_s).not_to include('swipe-action')
        expect(notification_item.at_css('.swipe-action-background')).to be_nil
        expect(delete_form).to be_present
        expect(delete_form.at_css('input[name="_method"]')['value']).to eq('delete')
        expect(delete_button['data-turbo-confirm']).to eq(I18n.t('notifications.item.delete_confirm'))
        expect(delete_button['data-confirm-variant']).to eq('danger')
        expect(delete_button['data-confirm-icon']).to eq('delete')
        expect(delete_button['data-confirm-confirm-label']).to eq(I18n.t('notifications.item.delete'))
        expect(delete_button['data-confirm-title']).to eq(I18n.t('notifications.item.delete_confirm_title'))
        expect(delete_button['data-confirm-backdrop']).to eq('plain')
        expect(delete_button.text).to include('close', I18n.t('notifications.item.delete'))
        expect(delete_button['aria-label']).to eq(I18n.t('notifications.item.delete_aria', title: notification.title))
        expect(delete_button['title']).to eq(I18n.t('notifications.item.delete_aria', title: notification.title))
      end
    end

    it '削除確認設定がOFFなら通知一覧の削除confirmを出さない' do
      user.update!(delete_confirmation_enabled: false)
      notification = create(:notification, user:, title: '自分の通知')

      get notifications_path

      document = Nokogiri::HTML(response.body)
      delete_form = document.at_css("#notifications_list form[action='#{notification_path(notification)}'][method='post']")
      delete_button = delete_form.at_css('button')

      expect(delete_button['data-turbo-confirm']).to be_nil
    end

    it '削除済みreceiptの通知は一覧に削除済みreceipt pathを出さない' do
      create(
        :notification,
        :read,
        user:,
        title: '削除済みレシート通知',
        notifiable_type: 'Receipt',
        notifiable_id: missing_receipt_id,
        action_path: receipt_path(missing_receipt_public_id)
      )

      get notifications_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css(%(a[href="#{receipt_path(missing_receipt_public_id)}"]))).to be_nil
        expect(response.body).to include(I18n.t('notifications.item.deleted_target'))
      end
    end

    it '通知保持件数設定が20ならDB保持分の20件を表示する' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(20))
      insert_notifications_for(user, count: 20)

      get notifications_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('#notifications_list article[id^="notification_"]').size).to eq(20)
      end
    end

    it '通知保持件数設定が100でも一覧は最新50件まで表示する' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(100))
      insert_notifications_for(user, count: 60)

      get notifications_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('#notifications_list article[id^="notification_"]').size).to eq(Notification::INDEX_LIMIT)
      end
    end

    it '通知保持件数設定が500でも一覧は最新50件まで表示する' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      insert_notifications_for(user, count: 60)

      get notifications_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('#notifications_list article[id^="notification_"]').size).to eq(Notification::INDEX_LIMIT)
      end
    end
  end

  describe 'PATCH /notifications/:uid/read' do
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
        expect(receipt_path(receipt)).to eq("/receipts/#{receipt.public_id}")
        expect(notification.action_path).to eq("/receipts/#{receipt.public_id}")
        expect(response).to redirect_to(receipt_path(receipt))
        expect(notification.reload).to be_read
      end
    end

    it '内部IDのURLでは既読化できない' do
      notification = create(:notification, user:, read_at: nil)

      patch "/notifications/#{notification.id}/read"

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(notification.reload).to be_unread
      end
    end

    it '削除済みreceiptの通知は既読化後に通知一覧へ戻す' do
      notification = create(
        :notification,
        user:,
        notifiable_type: 'Receipt',
        notifiable_id: missing_receipt_id,
        action_path: receipt_path(missing_receipt_public_id),
        read_at: nil
      )

      patch read_notification_path(notification)

      aggregate_failures do
        expect(response).to redirect_to(notifications_path)
        expect(notification.reload).to be_read
        expect(flash[:warning]).to eq(I18n.t('notifications.item.deleted_target'))
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

      expect(Notification).to receive(:broadcast_realtime_surfaces_for).with(user).and_call_original

      patch read_all_notifications_path

      aggregate_failures do
        expect(response).to redirect_to(notifications_path)
        expect(user.notifications.unread.count).to eq(0)
        expect(other_notification.reload).to be_unread
      end
    end
  end

  describe 'DELETE /notifications/:uid' do
    it '自分の未読通知を削除し、未読件数も減らす' do
      notification = create(:notification, user:, read_at: nil)

      expect {
        delete notification_path(notification)
      }.to change(user.notifications, :count).by(-1)

      aggregate_failures do
        expect(response).to redirect_to(notifications_path)
        expect(user.notifications.unread.count).to eq(0)
        expect(Notification.exists?(notification.id)).to be(false)
      end
    end

    it '既読通知も削除できる' do
      notification = create(:notification, :read, user:)

      expect {
        delete notification_path(notification)
      }.to change(user.notifications, :count).by(-1)

      expect(response).to redirect_to(notifications_path)
    end

    it '内部IDのURLでは削除できない' do
      notification = create(:notification, user:)

      expect {
        delete "/notifications/#{notification.id}"
      }.not_to change(Notification, :count)

      expect(response).to have_http_status(:not_found)
    end

    it '削除済みreceiptに紐づくstale通知も削除できる' do
      notification = create(
        :notification,
        user:,
        notifiable_type: 'Receipt',
        notifiable_id: missing_receipt_id,
        action_path: receipt_path(missing_receipt_public_id)
      )

      expect {
        delete notification_path(notification)
      }.to change(user.notifications, :count).by(-1)

      expect(response).to redirect_to(notifications_path)
    end

    it '他人の通知は削除できない' do
      notification = create(:notification, user: create(:user))

      expect {
        delete notification_path(notification)
      }.not_to change(Notification, :count)

      expect(response).to have_http_status(:not_found)
    end

    it 'Turbo requestではcontroller responseに重複通知surfaceを含めない' do
      notification = create(:notification, user:, read_at: nil)

      delete notification_path(notification), headers: { 'ACCEPT' => Mime[:turbo_stream].to_s }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('notifications_unread_badge')
        expect(response.body).not_to include('notifications_dropdown_content')
        expect(response.body).not_to include('notifications_index_header')
        expect(response.body).not_to include('notifications_list')
        expect(Notification.exists?(notification.id)).to be(false)
      end
    end
  end

  def insert_notifications_for(user, count:)
    now = Time.current
    attributes = count.times.map do |index|
      created_at = count.minutes.ago + index.minutes
      {
        user_id: user.id,
        uid: "ntf_#{SecureRandom.base58(16)}",
        kind: 'receipt_completed',
        title: "通知#{index}",
        body: '本文',
        action_path: "/receipts/rcpt_#{index.to_s(36).upcase.rjust(16, 'A')}",
        read_at: nil,
        metadata: {},
        created_at: created_at,
        updated_at: now
      }
    end

    Notification.insert_all!(attributes)
  end
end
