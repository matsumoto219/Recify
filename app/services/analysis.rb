module Analysis
  class << self
    def build_receipt_params(...)
      ReceiptBuildParamsService.call(...)
    end

    def processing_error_mapping(error_code)
      ReceiptProcessingErrorMapper.map(error_code)
    end

    def processing_error_category(error_code)
      processing_error_mapping(error_code)[:error_category]&.to_sym
    end

    def detect_category(text)
      ReceiptFallbackPatterns.detect_category(text)
    end

    def evaluate_receipt_signal(...)
      ReceiptSignalEvaluator.call(...)
    end

    def normalize_receipt_items(...)
      ReceiptItemNormalizer.normalize_ai_items(...)
    end

    def receipt_item_ai_allowed_keys
      ReceiptItemNormalizer::AI_ALLOWED_KEYS
    end

    def retry_receipt_analysis(...)
      RetryService.call(...)
    end

    def retry_eligibility(...)
      RetryService.eligibility(...)
    end

    def retry_types
      RetryService::RETRY_TYPES
    end

    def retry_confirmation_text
      RetryService::CONFIRMATION_TEXT
    end
  end
end
