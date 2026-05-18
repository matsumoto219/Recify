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

  after_create_commit :broadcast_unread_badge
  after_update_commit :broadcast_unread_badge, if: :saved_change_to_read_at?

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

  def broadcast_unread_badge
    broadcast_replace_later_to(
      [ user, :notifications ],
      target: "notifications_unread_badge",
      partial: "shared/notifications/badge",
      locals: { unread_count: user.notifications.unread.count }
    )
  end
end
