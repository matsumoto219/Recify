class NotificationCleanupJob < ApplicationJob
  queue_as :default

  def perform
    Notification.cleanup_old!
  end
end
