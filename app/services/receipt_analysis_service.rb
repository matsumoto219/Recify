class ReceiptAnalysisService
  class AnalysisError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  def self.call(receipt)
    ocr_result = ReceiptOcrService.call(receipt.image)
    ReceiptAiEnrichmentService.call(ocr_result)
  rescue ReceiptOcrService::OcrError => e
    raise AnalysisError.new(e.error_code, e.message)
  rescue ReceiptAiEnrichmentService::AiEnrichmentError => e
    raise AnalysisError.new(e.error_code, e.message)
  rescue StandardError => e
    raise AnalysisError.new("unexpected_error", e.message)
  end
end
