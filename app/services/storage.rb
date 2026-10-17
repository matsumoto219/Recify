module Storage
  class QuotaExceeded < StandardError
    attr_reader :scope

    def initialize(scope:)
      @scope = scope.to_sym
      super("storage quota exceeded")
    end
  end

  class << self
    def purge_attachment(attachment)
      AttachmentPurger.call(attachment)
    end

    def system_usage_snapshot
      SystemUsageSnapshot.call
    end

    def global_quota
      GlobalQuota.call
    end

    def global_quota_can_add?(...)
      GlobalQuota.can_add?(...)
    end

    def with_quota_reservation(byte_size:, user: nil, excluding_blob: nil, &operation)
      QuotaReservation.call(byte_size:, user:, excluding_blob:, &operation)
    end

    def with_prepared_images(records:, attachment_name:, user: nil, registration_key: nil, &operation)
      PreparedImages.call(records:, attachment_name:, user:, registration_key:, &operation)
    end

    def with_upload_operation_lock(key:, &operation)
      UploadLock.call(key:, namespace: "registrations", &operation)
    end

    def pending_prepared_registration?(user_id:, operation_key:)
      PreparedImageCleanup.scope.where(
        "metadata::jsonb -> ? ->> 'user_id' = ? AND metadata::jsonb -> ? ->> 'registration_key' = ?",
        PreparedImages::METADATA_KEY, user_id.to_s, PreparedImages::METADATA_KEY, operation_key
      ).exists?
    end

    def cleanup_prepared_images(...)
      PreparedImageCleanup.call(...)
    end

    def orphan_blob_scan(...)
      OrphanBlobScanner.call(...)
    end

    def purge_receipt_images(...)
      ReceiptImagePurger.call(...)
    end

    def extract_image_dimensions(...)
      ImageDimensions.extract(...)
    end

    def usage_calculator(user)
      UsageCalculator.new(user)
    end
  end
end
