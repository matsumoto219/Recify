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

  after_create_commit :broadcast_realtime_surfaces_after_create
  after_update_commit :broadcast_realtime_surfaces_after_read_change, if: :saved_change_to_read_at?

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

    private

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

  private

  def broadcast_realtime_surfaces_after_create
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces_after_read_change
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces
    self.class.broadcast_realtime_surfaces_for(user)
  end
end
