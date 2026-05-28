module Storage
  class << self
    def purge_attachment(attachment)
      AttachmentPurger.call(attachment)
    end

    def system_usage_snapshot
      SystemUsageSnapshot.call
    end

    def orphan_blob_scan(...)
      OrphanBlobScanner.call(...)
    end

    def usage_calculator(user)
      UsageCalculator.new(user)
    end

    alias usage_for usage_calculator
  end
end
