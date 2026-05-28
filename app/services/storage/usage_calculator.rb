module Storage
  class UsageCalculator
    ERROR_USAGE_PERCENTAGE = 95
    ERROR_REMAINING_BYTES = 50.megabytes
    WARNING_USAGE_PERCENTAGE = 80
    WARNING_REMAINING_BYTES = 200.megabytes
    WARNING_REMAINING_LIMIT_BYTES = 1.gigabyte

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def used_bytes
      @used_bytes ||= attachment_bytes(storage_attachments)
    end

    def limit_bytes
      @limit_bytes ||= UserLimits.effective_limit(user: user, key: "storage_bytes").to_i
    end

    def remaining_bytes
      @remaining_bytes ||= limit_bytes - used_bytes
    end

    def usage_ratio
      @usage_ratio ||= begin
        current_limit = limit_bytes
        if current_limit <= 0
          0.0
        else
          used_bytes.to_f / current_limit
        end
      end
    end

    def usage_percentage
      @usage_percentage ||= usage_ratio * 100
    end

    def state
      @state ||= begin
        if error?
          :error
        elsif warning?
          :warning
        else
          :normal
        end
      end
    end

    def can_add?(byte_size, excluding_blob: nil)
      current_used_bytes = excluding_blob ? used_bytes_excluding(excluding_blob) : used_bytes
      candidate_used_bytes = current_used_bytes + byte_size.to_i

      candidate_used_bytes <= limit_bytes
    end

    private

    def error?
      usage_percentage >= ERROR_USAGE_PERCENTAGE ||
        (large_storage_limit? && remaining_bytes < ERROR_REMAINING_BYTES)
    end

    def warning?
      usage_percentage >= WARNING_USAGE_PERCENTAGE ||
        (large_storage_limit? && remaining_bytes < WARNING_REMAINING_BYTES)
    end

    def large_storage_limit?
      limit_bytes >= WARNING_REMAINING_LIMIT_BYTES
    end

    def used_bytes_excluding(blob)
      attachments = storage_attachments
      attachments = attachments.where.not(blob_id: blob.id) if blob&.id

      attachment_bytes(attachments)
    end

    def attachment_bytes(attachments)
      attachments.joins(:blob).sum("active_storage_blobs.byte_size")
    end

    def storage_attachments
      ActiveStorage::Attachment.where(
        receipt_image_attachment_scope
      ).or(
        ActiveStorage::Attachment.where(avatar_attachment_scope)
      )
    end

    def receipt_image_attachment_scope
      {
        record_type: "Receipt",
        record_id: user.receipts.select(:id),
        name: "image"
      }
    end

    def avatar_attachment_scope
      {
        record_type: "User",
        record_id: user.id,
        name: "avatar"
      }
    end
  end
end
