require 'rails_helper'

RSpec.describe Notification, type: :model do
  describe 'validations' do
    it 'allowed kindだけを許可する' do
      notification = build(:notification, kind: 'receipt_completed')
      invalid_notification = build(:notification, kind: 'unknown')

      aggregate_failures do
        expect(notification).to be_valid
        expect(invalid_notification).not_to be_valid
        expect(invalid_notification.errors[:kind]).to be_present
      end
    end
  end

  describe 'scopes' do
    it 'unread/read/recent を返す' do
      user = create(:user)
      old_unread = create(:notification, user:, read_at: nil, created_at: 2.days.ago)
      read = create(:notification, user:, read_at: 1.hour.ago, created_at: 1.day.ago)
      new_unread = create(:notification, user:, read_at: nil, created_at: Time.current)

      aggregate_failures do
        expect(described_class.unread).to contain_exactly(old_unread, new_unread)
        expect(described_class.read).to contain_exactly(read)
        expect(described_class.recent).to eq([ new_unread, read, old_unread ])
      end
    end
  end

  describe '#read? / #unread? / #mark_as_read!' do
    it '既読状態を扱える' do
      notification = create(:notification, read_at: nil)

      aggregate_failures do
        expect(notification).to be_unread
        expect(notification).not_to be_read
      end

      notification.mark_as_read!

      aggregate_failures do
        expect(notification).to be_read
        expect(notification).not_to be_unread
        expect(notification.read_at).to be_present
      end
    end
  end

  describe 'broadcasts' do
    it '作成時に未読badgeをreplaceする' do
      user = create(:user)
      notification = build_stubbed(:notification, user:)

      expect(notification).to receive(:broadcast_replace_later_to).with(
        [ user, :notifications ],
        target: 'notifications_unread_badge',
        partial: 'shared/notifications/badge',
        locals: { unread_count: user.notifications.unread.count }
      )

      notification.send(:broadcast_unread_badge)
    end
  end
end
