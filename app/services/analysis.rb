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
  end
end
