class NotificationCleanupJob < ApplicationJob
  queue_as :default

  def self.enqueue_after_commit
    ActiveRecord.after_all_transactions_commit do
      Rails.logger.warn("[NotificationCleanupJob] enqueue_failed") unless perform_later
    rescue StandardError => e
      Rails.logger.warn("[NotificationCleanupJob] enqueue_failed error_class=#{e.class.name}")
    end
  end

  def perform
    Notification.cleanup_old!
  end
end
