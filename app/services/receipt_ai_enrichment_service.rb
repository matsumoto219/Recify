class ReceiptAiEnrichmentService
  class AiEnrichmentError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  def self.call(ocr_result)
    raw_lines = ocr_result[:raw_lines]
    raise AiEnrichmentError.new("analysis_missing_keys", "OCR結果が不正です") unless raw_lines.is_a?(Array)

    {
      store_name: "サンプルストア",
      purchased_at: Time.current,
      total_amount: 1280,
      payment_method: "credit_card",
      status: "review_needed",
      items: [
        {
          raw_text: "ｺｰﾋｰ",
          suggested_name: "コーヒー",
          confirmed_name: "コーヒー",
          category: "drink",
          price: 180,
          quantity: 1,
          line_total: 180,
          needs_review: false,
          position_index: 1,
          confidence: 0.95
        },
        {
          raw_text: "ｻﾝﾄﾞ",
          suggested_name: "サンドイッチ",
          confirmed_name: "サンドイッチ",
          category: "food",
          price: 550,
          quantity: 2,
          line_total: 1100,
          needs_review: true,
          position_index: 2,
          confidence: 0.72
        }
      ]
    }
  rescue KeyError
    raise AiEnrichmentError.new("analysis_missing_keys", "OCR結果の必須項目が不足しています")
  rescue NoMethodError, TypeError
    raise AiEnrichmentError.new("analysis_items_invalid", "OCR結果の形式が不正です")
  end
end
