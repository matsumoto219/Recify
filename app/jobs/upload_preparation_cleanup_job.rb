class UploadPreparationCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 100

  def perform(limit: DEFAULT_LIMIT, images_after_id: 0, images_through_id: nil, registrations_after_id: 0, registrations_through_id: nil)
    images = Storage.cleanup_prepared_images(limit:, after_id: images_after_id, through_id: images_through_id)
    registrations = Receipts::Registrations.cleanup_expired(limit:, after_id: registrations_after_id, through_id: registrations_through_id)
    enqueue_next_page(limit:, images:, registrations:) if images.next_after_id || registrations.next_after_id

    {
      prepared_images_deleted: images.deleted,
      registrations_scanned: registrations.scanned,
      registrations_deleted: registrations.deleted,
      registrations_pending: registrations.pending,
      registrations_busy: registrations.busy,
      registrations_failed: registrations.failed
    }
  end

  private

  def enqueue_next_page(limit:, images:, registrations:)
    job = self.class.perform_later(
      limit:,
      images_after_id: images.next_after_id || images.through_id,
      images_through_id: images.through_id,
      registrations_after_id: registrations.next_after_id || registrations.through_id,
      registrations_through_id: registrations.through_id
    )
    Rails.logger.warn("[UploadPreparationCleanupJob] enqueue_failed") unless job
  rescue StandardError => e
    Rails.logger.warn("[UploadPreparationCleanupJob] enqueue_failed error_class=#{e.class}")
  end
end
