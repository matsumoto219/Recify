require 'rails_helper'

RSpec.describe NotificationsHelper, type: :helper do
  describe '#notification_dropdown_item_state' do
    it 'returns unread dropdown row state with icon and delete confirmation data' do
      user = create(:user, delete_confirmation_enabled: true)
      notification = create(:notification, user: user, kind: 'receipt_failed')

      state = helper.notification_dropdown_item_state(notification)

      aggregate_failures do
        expect(state).to be_unread
        expect(state).not_to be_stale_notifiable
        expect(state.read_path).to eq(read_notification_path(notification))
        expect(state.delete_confirm_data).to eq(
          turbo_confirm: I18n.t('notifications.item.delete_confirm'),
          confirm_variant: 'danger',
          confirm_icon: 'delete',
          confirm_confirm_label: I18n.t('notifications.item.delete'),
          confirm_title: I18n.t('notifications.item.delete_confirm_title'),
          confirm_backdrop: 'plain'
        )
        expect(state.icon).to eq('error')
        expect(state.icon_class).to eq('token-state-error-soft')
        expect(state.item_classes).to include('token-brand-soft-bg')
      end
    end
  end

  describe '#notification_list_item_state' do
    it 'returns read list row state and action path' do
      notification = create(:notification, :read, action_path: '/receipts/rcpt_test123456789')

      state = helper.notification_list_item_state(notification)

      aggregate_failures do
        expect(state).not_to be_unread
        expect(state).to be_action_available
        expect(state.action_path).to eq('/receipts/rcpt_test123456789')
        expect(state.item_classes).to include('token-bg-card')
        expect(state.item_classes).not_to include('token-brand-soft-bg')
      end
    end
  end
end
