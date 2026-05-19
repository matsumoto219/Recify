class NotificationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @notifications = current_user.notifications.recent.limit(50)
    @unread_count = current_user.notifications.unread.count
  end

  def read
    notification = current_user.notifications.find(params[:id])
    notification.mark_as_read!

    redirect_to safe_notification_redirect_path(notification)
  end

  def read_all
    current_user.notifications.unread.update_all(
      read_at: Time.current,
      updated_at: Time.current
    )
    Notification.broadcast_realtime_surfaces_for(current_user)

    redirect_to notifications_path
  end

  private

  def safe_notification_redirect_path(notification)
    path = notification.action_path.presence
    return notifications_path if path.blank?

    path.start_with?("/") ? path : notifications_path
  end
end
