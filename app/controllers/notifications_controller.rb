class NotificationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @notifications = Notification.preload_known_notifiables(current_user.notifications.recent.limit(50).to_a)
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
      format.turbo_stream { head :ok }
    end
  end

  private

  def safe_notification_redirect_path(notification)
    return notifications_path unless notification.action_available?

    notification.action_path
  end
end
