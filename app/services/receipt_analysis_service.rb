class ReceiptAnalysisService
  def self.call(receipt)
    ocr_result = ReceiptOcrService.call(receipt.image)
    ReceiptAiEnrichmentService.call(ocr_result)
  end
end
