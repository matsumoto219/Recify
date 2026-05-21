class NotificationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @notifications = current_user.notifications.recent.limit(50)
    @unread_count = current_user.notifications.unread.count
  end

  def read
    notification = current_user.notifications.find(params[:id])
    notification.mark_as_read!

    redirect_options = notification.stale_notifiable? ? { alert: t("notifications.item.deleted_target") } : {}
    redirect_to safe_notification_redirect_path(notification), **redirect_options
  end

  def read_all
    current_user.notifications.unread.update_all(
      read_at: Time.current,
      updated_at: Time.current
    )
    Notification.broadcast_realtime_surfaces_for(current_user)

    redirect_to notifications_path
  end

  def destroy
    notification = current_user.notifications.find(params[:id])
    notification.destroy!

    respond_to do |format|
      format.html { redirect_to notifications_path }
      format.turbo_stream { render turbo_stream: notification_surface_streams }
    end
  end

  private

  def safe_notification_redirect_path(notification)
    return notifications_path unless notification.action_available?

    notification.action_path
  end

  def notification_surface_streams
    unread_count = current_user.notifications.unread.count
    dropdown_notifications = current_user.notifications.recent.limit(Notification::DROPDOWN_LIMIT).to_a
    index_notifications = current_user.notifications.recent.limit(Notification::INDEX_LIMIT).to_a

    [
      turbo_stream.replace(
        "notifications_unread_badge",
        partial: "shared/notifications/badge",
        locals: { unread_count: unread_count }
      ),
      turbo_stream.replace(
        "notifications_dropdown_content",
        partial: "shared/notifications/dropdown_content",
        locals: { notifications: dropdown_notifications }
      ),
      turbo_stream.replace(
        "notifications_index_header",
        partial: "notifications/header",
        locals: { unread_count: unread_count }
      ),
      turbo_stream.replace(
        "notifications_list",
        partial: "notifications/list",
        locals: { notifications: index_notifications }
      )
    ]
  end
end
