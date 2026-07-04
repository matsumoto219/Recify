class ReceiptAnalysisPipeline
  Result = Struct.new(
    :ocr_result,
    :ai_result,
    :finalize_decision,
    :next_step,
    :skip_reason,
    keyword_init: true
  ) do
    # Provider payload の成否を表す補助。Job の後続enqueue判定は next_step を使う。
    def success?
      result = ai_result || ocr_result

      result&.dig(:success) == true
    end
  end
end
