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

  describe 'query indexes' do
    it 'receipt通知用の重複防止unique indexを持つ' do
      indexes = ActiveRecord::Base.connection.indexes(:notifications)
      index = indexes.find { |candidate| candidate.name == 'index_notifications_on_user_kind_notifiable_unique' }

      aggregate_failures do
        expect(index).to be_present
        expect(index.columns).to eq(%w[user_id kind notifiable_type notifiable_id])
        expect(index.unique).to be(true)
        expect(index.where).to include('notifiable_type IS NOT NULL')
        expect(index.where).to include('notifiable_id IS NOT NULL')
      end
    end
  end

  describe 'uniqueness' do
    it '同じuser/kind/notifiableの通知はDBで重複作成できない' do
      receipt = create(:receipt, :completed)
      timestamp = Time.current
      attributes = {
        user_id: receipt.user_id,
        kind: 'receipt_completed',
        notifiable_type: 'Receipt',
        notifiable_id: receipt.id,
        title: 'レシート解析が完了しました',
        body: 'レシートを確認できます。',
        action_path: "/receipts/#{receipt.id}",
        metadata: { receipt_id: receipt.id, status: 'completed' },
        created_at: timestamp,
        updated_at: timestamp
      }

      described_class.insert_all!([ attributes ])

      expect {
        described_class.insert_all!([ attributes.merge(created_at: timestamp + 1.second, updated_at: timestamp + 1.second) ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
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
    it '作成時に永続通知UIをreplaceする' do
      user = create(:user)

      expect(described_class).to receive(:broadcast_realtime_surfaces_for).with(user)

      create(:notification, user:)
    end

    it '既読状態更新時に永続通知UIをreplaceする' do
      notification = create(:notification, read_at: nil)

      expect(described_class).to receive(:broadcast_realtime_surfaces_for).with(notification.user)

      notification.update!(read_at: Time.current)
    end

    it '削除時に永続通知UIをreplaceする' do
      notification = create(:notification)

      expect(described_class).to receive(:broadcast_realtime_surfaces_for).with(notification.user)

      notification.destroy!
    end

    it 'badge / dropdown / index header / list をreplaceする' do
      user = create(:user)
      create(:notification, user:, read_at: nil)

      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to)

      described_class.broadcast_realtime_surfaces_for(user)

      aggregate_failures do
        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_later_to).with(
          [ user, :notifications ],
          target: 'notifications_unread_badge',
          partial: 'shared/notifications/badge',
          locals: { unread_count: 1 }
        )

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_later_to).with(
          [ user, :notifications ],
          target: 'notifications_dropdown_content',
          partial: 'shared/notifications/dropdown_content',
          locals: { notifications: user.notifications.recent.limit(5).to_a }
        )

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_later_to).with(
          [ user, :notifications ],
          target: 'notifications_index_header',
          partial: 'notifications/header',
          locals: { unread_count: 1 }
        )

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_later_to).with(
          [ user, :notifications ],
          target: 'notifications_list',
          partial: 'notifications/list',
          locals: { notifications: user.notifications.recent.limit(50).to_a }
        )
      end
    end
  end

  describe '.cleanup_old!' do
    it '既読から30日を超えた通知を削除し、未読は残す' do
      user = create(:user)
      old_read = create(:notification, :read, user:, read_at: 31.days.ago)
      recent_read = create(:notification, :read, user:, read_at: 29.days.ago)
      old_unread = create(:notification, user:, created_at: 1.year.ago, read_at: nil)

      expect {
        described_class.cleanup_old!(now: Time.current)
      }.to change(described_class, :count).by(-1)

      aggregate_failures do
        expect(described_class.exists?(old_read.id)).to be(false)
        expect(described_class.exists?(recent_read.id)).to be(true)
        expect(described_class.exists?(old_unread.id)).to be(true)
      end
    end

    it 'userごとに最新100件を残して古い既読通知を削除する' do
      user = create(:user)
      other_user = create(:user)
      old_notifications = insert_notifications_for(user, count: 105, read_at: 1.day.ago)
      insert_notifications_for(other_user, count: 3, read_at: 1.day.ago)

      deleted_count = described_class.prune_for_user!(user, broadcast: false)

      aggregate_failures do
        expect(deleted_count).to eq(5)
        expect(user.notifications.count).to eq(100)
        expect(other_user.notifications.count).to eq(3)
        expect(described_class.where(id: old_notifications.first(5).map { |attributes| attributes[:id] })).to be_empty
      end
    end

    it '100件超でも未読通知は削除しない' do
      user = create(:user)
      insert_notifications_for(user, count: 100, read_at: 1.day.ago)
      unread_attributes = insert_notifications_for(user, count: 2, read_at: nil, created_at_start: 200.days.ago)

      deleted_count = described_class.prune_for_user!(user, broadcast: false)

      aggregate_failures do
        expect(deleted_count).to eq(0)
        expect(user.notifications.count).to eq(102)
        expect(described_class.where(id: unread_attributes.map { |attributes| attributes[:id] }).count).to eq(2)
      end
    end

    it '削除件数を返し、対象userのsurfaceを更新する' do
      user = create(:user)
      old_read = create(:notification, :read, user:, read_at: 31.days.ago)

      expect(described_class).to receive(:broadcast_realtime_surfaces_for).with(user)

      deleted_count = described_class.cleanup_old!(now: Time.current)

      aggregate_failures do
        expect(deleted_count).to eq(1)
        expect(described_class.exists?(old_read.id)).to be(false)
      end
    end
  end

  def insert_notifications_for(user, count:, read_at:, created_at_start: count.minutes.ago)
    now = Time.current
    attributes = count.times.map do |index|
      created_at = created_at_start + index.minutes
      {
        user_id: user.id,
        kind: 'receipt_completed',
        title: "通知#{index}",
        body: '本文',
        action_path: "/receipts/#{index}",
        read_at: read_at,
        metadata: {},
        created_at: created_at,
        updated_at: now
      }
    end

    described_class.insert_all!(attributes, returning: %w[id]).rows.map.with_index do |row, index|
      attributes[index].merge(id: row.first)
    end
  end
end
