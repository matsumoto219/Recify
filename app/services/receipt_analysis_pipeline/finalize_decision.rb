class ReceiptAnalysisPipeline
  FinalizeDecision = Struct.new(
    :finalize_strategy,
    :error_code,
    :error_message,
    :receipt_attributes,
    :ocr_result,
    :ai_result,
    :metadata,
    keyword_init: true
  ) do
    def strategy
      finalize_strategy
    end
  end
end
