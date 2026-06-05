require 'rails_helper'

RSpec.describe Notification, type: :model do
  describe 'validations' do
    it 'uidを自動生成し、形式を検証する' do
      notification = create(:notification)

      aggregate_failures do
        expect(notification.uid).to match(/\Antf_[A-Za-z0-9]{16}\z/)
        expect(notification.to_param).to eq(notification.uid)
      end
    end

    it 'uidの重複を不正にする' do
      existing = create(:notification)
      duplicate = build(:notification, uid: existing.uid)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:uid]).to be_present
    end

    it 'uid生成時に既存値との衝突を避ける' do
      duplicate_random = 'ABCDEFGHJKLMNPQR'
      unique_random = 'STUVWXYZabcdefgh'
      create(:notification, uid: "ntf_#{duplicate_random}")

      allow(SecureRandom).to receive(:base58).and_return(duplicate_random, unique_random)

      notification = create(:notification)

      expect(notification.uid).to eq("ntf_#{unique_random}")
    end

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
    it 'uidにunique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:notifications).find do |candidate|
        candidate.name == 'index_notifications_on_uid'
      end

      expect(index).to be_present
      expect(index.unique).to be(true)
    end

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
    it 'uidのDB unique index衝突時はuidを再生成して保存する' do
      existing = create(:notification)
      unique_random = 'STUVWXYZabcdefgh'
      notification = build(:notification, uid: existing.uid)

      allow(SecureRandom).to receive(:base58).and_return(unique_random)

      expect(notification.save!(validate: false)).to be(true)
      expect(notification.uid).to eq("ntf_#{unique_random}")
    end

    it 'uid以外のDB unique index衝突は再raiseする' do
      receipt = create(:receipt, :completed)
      create(:notification, user: receipt.user, kind: 'receipt_completed', notifiable: receipt)
      duplicate = build(:notification, user: receipt.user, kind: 'receipt_completed', notifiable: receipt, uid: 'ntf_STUVWXYZabcdefgh')

      expect {
        duplicate.save!(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it '同じuser/kind/notifiableの通知はDBで重複作成できない' do
      receipt = create(:receipt, :completed)
      timestamp = Time.current
      attributes = {
        user_id: receipt.user_id,
        uid: 'ntf_ABCDEFGHJKLMNPQR',
        kind: 'receipt_completed',
        notifiable_type: 'Receipt',
        notifiable_id: receipt.id,
        title: 'レシート解析が完了しました',
        body: 'レシートを確認できます。',
        action_path: "/receipts/#{receipt.public_id}",
        metadata: { receipt_id: receipt.id, status: 'completed' },
        created_at: timestamp,
        updated_at: timestamp
      }

      described_class.insert_all!([ attributes ])

      expect {
        described_class.insert_all!([ attributes.merge(uid: 'ntf_STUVWXYZabcdefgh', created_at: timestamp + 1.second, updated_at: timestamp + 1.second) ])
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

  describe '.preload_known_notifiables' do
    it '既知のnotifiableを一括preloadし、stale判定のN+1を避ける' do
      user = create(:user)
      receipts = create_list(:receipt, 3, user: user)
      notifications = receipts.map do |receipt|
        create(:notification, user: user, notifiable: receipt, action_path: "/receipts/#{receipt.public_id}")
      end
      notifications = described_class.where(id: notifications.map(&:id)).to_a

      queries = count_sql_queries do
        described_class.preload_known_notifiables(notifications)
        notifications.each { |notification| expect(notification.stale_notifiable?).to be(false) }
      end

      receipt_queries = queries.select { |sql| sql.include?('"receipts"') }
      expect(receipt_queries.size).to eq(1)
    end

    it '未知のnotifiable_typeはpreload対象にせず、stale扱いのまま落とさない' do
      notification = create(:notification, notifiable_type: 'RemovedNotificationTarget', notifiable_id: 123_456)

      expect {
        described_class.preload_known_notifiables([ notification ])
      }.not_to raise_error
      expect(notification.stale_notifiable?).to be(true)
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

    it '通知保持件数設定を変更しても既読30日cleanupは変わらない' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      user = create(:user)
      old_read = create(:notification, :read, user:, read_at: 31.days.ago)
      recent_read = create(:notification, :read, user:, read_at: 29.days.ago)

      described_class.cleanup_old!(now: Time.current)

      aggregate_failures do
        expect(described_class.exists?(old_read.id)).to be(false)
        expect(described_class.exists?(recent_read.id)).to be(true)
      end
    end

    it '既読保持期間設定が7日なら8日前の既読通知を削除し未読は残す' do
      create(:system_setting, key: 'retention.notifications_read_days', value: SystemSettings.stored_value(7))
      user = create(:user)
      old_read = create(:notification, :read, user:, read_at: 8.days.ago)
      recent_read = create(:notification, :read, user:, read_at: 6.days.ago)
      old_unread = create(:notification, user:, created_at: 1.year.ago, read_at: nil)

      described_class.cleanup_old!(now: Time.current)

      aggregate_failures do
        expect(described_class.exists?(old_read.id)).to be(false)
        expect(described_class.exists?(recent_read.id)).to be(true)
        expect(described_class.exists?(old_unread.id)).to be(true)
      end
    end

    it '既読保持期間設定が90日なら91日前の既読通知だけを削除する' do
      create(:system_setting, key: 'retention.notifications_read_days', value: SystemSettings.stored_value(90))
      user = create(:user)
      old_read = create(:notification, :read, user:, read_at: 91.days.ago)
      recent_read = create(:notification, :read, user:, read_at: 89.days.ago)

      described_class.cleanup_old!(now: Time.current)

      aggregate_failures do
        expect(described_class.exists?(old_read.id)).to be(false)
        expect(described_class.exists?(recent_read.id)).to be(true)
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

    it '通知保持件数設定が20なら最新20件を残して古い既読通知を削除する' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(20))
      user = create(:user)
      other_user = create(:user)
      old_notifications = insert_notifications_for(user, count: 21, read_at: 1.day.ago)
      insert_notifications_for(other_user, count: 21, read_at: 1.day.ago)

      deleted_count = described_class.prune_for_user!(user, broadcast: false)

      aggregate_failures do
        expect(deleted_count).to eq(1)
        expect(user.notifications.count).to eq(20)
        expect(other_user.notifications.count).to eq(21)
        expect(described_class.exists?(old_notifications.first[:id])).to be(false)
      end
    end

    it '通知保持件数設定が500なら最新500件を残して古い既読通知を削除する' do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      user = create(:user)
      old_notifications = insert_notifications_for(user, count: 501, read_at: 1.day.ago)

      deleted_count = described_class.prune_for_user!(user, broadcast: false)

      aggregate_failures do
        expect(deleted_count).to eq(1)
        expect(user.notifications.count).to eq(500)
        expect(described_class.exists?(old_notifications.first[:id])).to be(false)
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
        uid: "ntf_#{SecureRandom.base58(16)}",
        kind: 'receipt_completed',
        title: "通知#{index}",
        body: '本文',
        action_path: "/receipts/rcpt_#{index.to_s(36).upcase.rjust(16, 'A')}",
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

  def count_sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      name = payload[:name].to_s
      sql = payload[:sql].to_s.squish
      next if name == 'SCHEMA' || name == 'TRANSACTION' || payload[:cached]
      next if sql.include?('schema_migrations') || sql.include?('ar_internal_metadata')

      queries << sql
    end

    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        yield
      end
    end
    queries
  end
end
