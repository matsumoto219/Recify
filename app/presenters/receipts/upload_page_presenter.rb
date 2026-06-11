module Receipts
  class UploadPagePresenter
    def initialize(user:, ocr_state:, ai_state:)
      @user = user
      @ocr_state_payload = ocr_state
      @ai_state_payload = ai_state
    end

    def ocr_down?
      ocr_state == "down"
    end

    def ocr_degraded?
      ocr_state == "degraded"
    end

    def ai_down?
      ai_state == "down"
    end

    def ai_degraded?
      ai_state == "degraded"
    end

    def ocr_available?
      !ocr_down?
    end

    def file_count_limit
      ReceiptBatchUploadService.max_files
    end

    def file_count_limit_message
      I18n.t("receipts.new_upload.js.max_files", max: file_count_limit)
    end

    def multiple_upload_hint
      I18n.t("receipts.new_upload.multiple_hint", max: file_count_limit)
    end

    def storage_used_bytes
      storage_usage.used_bytes
    end

    def storage_limit_bytes
      storage_usage.limit_bytes
    end

    def storage_usage
      @storage_usage ||= user.storage_usage
    end

    private

    attr_reader :user, :ocr_state_payload, :ai_state_payload

    def ocr_state
      state_from(ocr_state_payload)
    end

    def ai_state
      state_from(ai_state_payload)
    end

    def state_from(payload)
      (payload || {}).with_indifferent_access[:state].to_s
    end
  end
end
