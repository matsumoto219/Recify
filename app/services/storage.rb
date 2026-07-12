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
