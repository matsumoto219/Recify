module Storage
  class PreparedImageCleanup
    Result = Data.define(:scanned, :deleted, :next_after_id, :through_id)
    private_constant :Result

    def self.scope
      ActiveStorage::Blob.where("jsonb_exists(metadata::jsonb, ?)", PreparedImages::METADATA_KEY)
    end

    def self.call(limit: 100, after_id: 0, through_id: nil)
      raise ArgumentError, "invalid cleanup limit" unless limit.is_a?(Integer) && limit.between?(1, 1000)
      unless after_id.is_a?(Integer) && after_id >= 0 &&
          (through_id.nil? || (through_id.is_a?(Integer) && through_id >= after_id))
        raise ArgumentError, "invalid cleanup cursor"
      end

      through_id ||= expired_scope.maximum(:id).to_i
      candidates = expired_scope.where(id: (after_id + 1)..through_id)
      records = candidates.order(:id).limit(limit).to_a
      purged = 0
      records.each do |blob|
        metadata = blob.metadata[PreparedImages::METADATA_KEY]
        next unless metadata.is_a?(Hash) && metadata["attempt"].is_a?(String) && metadata["attempt"].match?(/\A[0-9a-f]{64}\z/)
        next unless Time.iso8601(metadata.fetch("expires_at")) <= Time.current

        UploadLock.call(key: metadata["attempt"], namespace: "images") do
          purged += 1 if discard(blob.id, attempt: metadata["attempt"])
        end
      rescue ArgumentError, KeyError
        next
      rescue StandardError => error
        Rails.logger.warn("[Storage] prepared_image_cleanup_failed error_class=#{error.class}")
      end
      next_after_id = records.last.id if records.any? && candidates.where("active_storage_blobs.id > ?", records.last.id).exists?
      Result.new(scanned: records.size, deleted: purged, next_after_id:, through_id:)
    end

    # The caller holds the file lock until body deletion and row deletion finish.
    def self.discard(id, attempt:)
      blob = ActiveStorage::Blob.find_by(id:)
      return false unless blob

      disposable = blob.with_lock do
        metadata = blob.metadata[PreparedImages::METADATA_KEY]
        next false unless metadata.is_a?(Hash) && metadata["attempt"] == attempt && !blob.attachments.exists?

        # Failed deletion remains tracked and can be retried without waiting for the staging TTL.
        blob.update_columns(metadata: blob.metadata.merge(
          PreparedImages::METADATA_KEY => metadata.merge("expires_at" => Time.current.utc.iso8601)
        ))
        true
      end
      return false unless disposable

      blob.delete
      blob.destroy!
      true
    end

    def self.expired_scope
      scope.where.missing(:attachments).where(
        "metadata::jsonb -> ? ->> 'expires_at' <= ?",
        PreparedImages::METADATA_KEY, Time.current.utc.iso8601
      )
    end
    private_class_method :expired_scope
  end
end
