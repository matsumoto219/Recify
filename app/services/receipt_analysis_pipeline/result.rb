class ReceiptAnalysisPipeline
  Result = Struct.new(:ocr_result, keyword_init: true) do
    def success?
      ocr_result&.dig(:success) == true
    end
  end
end
