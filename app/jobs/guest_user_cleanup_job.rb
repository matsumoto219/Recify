class GuestUserCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_SIZE = 100
  DEFAULT_MAX_RECORDS = 1000

  def perform(batch_size: DEFAULT_BATCH_SIZE, max_records: DEFAULT_MAX_RECORDS)
    batch_size = normalize_positive_integer(batch_size, DEFAULT_BATCH_SIZE)
    max_records = normalize_positive_integer(max_records, DEFAULT_MAX_RECORDS)
    cutoff = User.guest_cleanup_retention_period.ago
    deleted_count = 0
    failed_count = 0

    User.guest_cleanup_candidates(cutoff)
      .limit(max_records)
      .find_each(batch_size: batch_size) do |user|
        deleted_count += 1 if destroy_guest_user!(user, cutoff: cutoff)
      rescue StandardError => e
        failed_count += 1
        log_destroy_failure(user, e)
      end

    log_completion(deleted_count:, failed_count:, batch_size:, max_records:)

    {
      deleted_count: deleted_count,
      failed_count: failed_count
    }
  end

  private

  def destroy_guest_user!(user, cutoff:)
    if Receipt.respond_to?(:suppressing_turbo_broadcasts)
      Receipt.suppressing_turbo_broadcasts { destroy_guest_user_transaction!(user, cutoff: cutoff) }
    else
      destroy_guest_user_transaction!(user, cutoff: cutoff)
    end
  end

  def destroy_guest_user_transaction!(user, cutoff:)
    user.with_lock do
      return false unless User.guest_cleanup_candidates(cutoff).where(id: user.id).exists?

      user.notifications.delete_all
      user.destroy!
      true
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  def normalize_positive_integer(value, fallback)
    integer = value.to_i

    integer.positive? ? integer : fallback
  end

  def log_destroy_failure(user, error)
    Rails.logger.error(
      "[GuestUserCleanupJob] failed user_id=#{user.id} error_class=#{error.class} " \
      "message=#{SecurityEvents.sanitize_exception_message(error.message)}"
    )
  end

  def log_completion(deleted_count:, failed_count:, batch_size:, max_records:)
    Rails.logger.info(
      "[GuestUserCleanupJob] completed deleted_count=#{deleted_count} failed_count=#{failed_count} " \
      "batch_size=#{batch_size} max_records=#{max_records}"
    )
  end
end
