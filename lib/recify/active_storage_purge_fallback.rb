module Recify
  module ActiveStoragePurgeFallback
    def purge_later
      enqueue_result = super
      return enqueue_result if enqueue_result

      purge_after_enqueue_failure
    rescue StandardError => error
      raise unless solid_queue_enqueue_error?(error)

      purge_after_enqueue_failure
    end

    private

    def solid_queue_enqueue_error?(error)
      defined?(SolidQueue::Job::EnqueueError) && error.is_a?(SolidQueue::Job::EnqueueError)
    end

    def purge_after_enqueue_failure
      purge
    rescue StandardError => error
      Rails.logger.error(
        "[ActiveStoragePurgeFallback] blob_id=#{id || 'nil'} class=#{error.class.name}"
      )
      nil
    end
  end
end
