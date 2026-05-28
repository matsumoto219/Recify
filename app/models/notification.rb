class Notification < ApplicationRecord
  KINDS = %w[
    receipt_completed
    receipt_review_needed
    receipt_failed
  ].freeze

  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :read, -> { where.not(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  DROPDOWN_LIMIT = 5
  INDEX_LIMIT = 50
  READ_RETENTION_DAYS = 30
  MAX_NOTIFICATIONS_PER_USER = 100

  after_create_commit :broadcast_realtime_surfaces_after_create
  after_create_commit :prune_user_notifications_after_create
  after_update_commit :broadcast_realtime_surfaces_after_read_change, if: :saved_change_to_read_at?
  after_destroy_commit :broadcast_realtime_surfaces_after_destroy

  class << self
    def broadcast_realtime_surfaces_for(user)
      return unless user

      unread_count = user.notifications.unread.count
      dropdown_notifications = user.notifications.recent.limit(DROPDOWN_LIMIT).to_a
      index_notifications = user.notifications.recent.limit(INDEX_LIMIT).to_a

      broadcast_unread_badge_for(user, unread_count:)
      broadcast_dropdown_content_for(user, notifications: dropdown_notifications)
      broadcast_index_header_for(user, unread_count:)
      broadcast_index_list_for(user, notifications: index_notifications)
    end

    def preload_known_notifiables(notifications)
      records = Array(notifications)
      preloadable_records = records.select { |notification| preloadable_notifiable?(notification) }
      ActiveRecord::Associations::Preloader.new(records: preloadable_records, associations: :notifiable).call if preloadable_records.any?

      records
    end

    def cleanup_old!(now: Time.current)
      threshold = now - READ_RETENTION_DAYS.days
      affected_user_ids = read.where("read_at < ?", threshold).distinct.pluck(:user_id)
      deleted_count = read.where("read_at < ?", threshold).delete_all

      distinct.pluck(:user_id).each do |user_id|
        pruned_count = prune_for_user!(user_id, broadcast: false)
        next if pruned_count.zero?

        deleted_count += pruned_count
        affected_user_ids << user_id
      end

      broadcast_cleanup_for(affected_user_ids.uniq)
      deleted_count
    end

    def prune_for_user!(user_or_id, broadcast: true)
      user = user_or_id.is_a?(User) ? user_or_id : User.find_by(id: user_or_id)
      return 0 unless user

      protected_ids = user.notifications.recent.limit(MAX_NOTIFICATIONS_PER_USER).pluck(:id)
      deletable_scope = user.notifications.read
      deletable_scope = deletable_scope.where.not(id: protected_ids) if protected_ids.any?
      deleted_count = deletable_scope.delete_all

      broadcast_realtime_surfaces_for(user) if broadcast && deleted_count.positive?
      deleted_count
    end

    private

    def preloadable_notifiable?(notification)
      return false if notification.notifiable_type.blank? || notification.notifiable_id.blank?

      klass = notification.notifiable_type.safe_constantize
      klass && klass < ActiveRecord::Base
    end

    def broadcast_cleanup_for(user_ids)
      User.where(id: user_ids).find_each do |user|
        broadcast_realtime_surfaces_for(user)
      end
    end

    def broadcast_unread_badge_for(user, unread_count:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_unread_badge",
        partial: "shared/notifications/badge",
        locals: { unread_count: unread_count }
      )
    end

    def broadcast_dropdown_content_for(user, notifications:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_dropdown_content",
        partial: "shared/notifications/dropdown_content",
        locals: { notifications: notifications }
      )
    end

    def broadcast_index_header_for(user, unread_count:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_index_header",
        partial: "notifications/header",
        locals: { unread_count: unread_count }
      )
    end

    def broadcast_index_list_for(user, notifications:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_list",
        partial: "notifications/list",
        locals: { notifications: notifications }
      )
    end
  end

  def read?
    read_at.present?
  end

  def unread?
    !read?
  end

  def mark_as_read!
    return true if read?

    update!(read_at: Time.current)
  end

  def stale_notifiable?
    return false if notifiable_type.blank? || notifiable_id.blank?

    notifiable.blank?
  rescue NameError
    true
  end

  def action_available?
    internal_action_path? && !stale_notifiable?
  end

  private

  def internal_action_path?
    path = action_path.to_s

    path.start_with?("/") && !path.start_with?("//")
  end

  def broadcast_realtime_surfaces_after_create
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces_after_read_change
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces_after_destroy
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces
    self.class.broadcast_realtime_surfaces_for(user)
  end

  def prune_user_notifications_after_create
    self.class.prune_for_user!(user)
  end
end
