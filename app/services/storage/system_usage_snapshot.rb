module Storage
  class SystemUsageSnapshot
    class << self
      def call
        new.call
      end
    end

    def call
      {
        total_blob_count: total_blobs.count,
        attached_blob_count: attached_blobs.count,
        orphan_blob_count: orphan_blobs.count,
        total_blob_bytes: total_blobs.sum(:byte_size),
        attached_blob_bytes: attached_blobs.sum(:byte_size),
        orphan_blob_bytes: orphan_blobs.sum(:byte_size),
        user_count: User.count,
        quota_total_bytes: User.sum(:storage_limit_bytes),
        quota_used_bytes: quota_used_bytes,
        global_quota: Storage.global_quota.to_h
      }
    end

    private

    def total_blobs
      ActiveStorage::Blob.all
    end

    def attached_blobs
      ActiveStorage::Blob.where(id: attached_blob_ids)
    end

    def orphan_blobs
      ActiveStorage::Blob.unattached
    end

    def attached_blob_ids
      ActiveStorage::Attachment.select(:blob_id).distinct
    end

    def quota_used_bytes
      quota_attachments.joins(:blob).sum("active_storage_blobs.byte_size")
    end

    def quota_attachments
      ActiveStorage::Attachment.where(receipt_image_attachment_scope).or(
        ActiveStorage::Attachment.where(avatar_attachment_scope)
      )
    end

    def receipt_image_attachment_scope
      {
        record_type: "Receipt",
        name: "image"
      }
    end

    def avatar_attachment_scope
      {
        record_type: "User",
        name: "avatar"
      }
    end
  end
end
