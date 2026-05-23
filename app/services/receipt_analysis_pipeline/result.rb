class ReceiptAnalysisPipeline
  Result = Struct.new(:ocr_result, :ai_result, keyword_init: true) do
    def success?
      result = ai_result || ocr_result

      result&.dig(:success) == true
    end
  end
end
