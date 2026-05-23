class ReceiptAnalysisPipeline
  class AiStep
    def self.call(run:, ocr_result:, ai_name_completion_enabled: false)
      new(
        run: run,
        ocr_result: ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled
      ).call
    end

    def initialize(run:, ocr_result:, ai_name_completion_enabled: false)
      @run = run
      @ocr_result = ocr_result
      @ai_name_completion_enabled = ai_name_completion_enabled == true
    end

    def call
      ReceiptAnalysisRuns.start_stage(run, "ai")

      ai_result = ReceiptAiEnrichmentService.call(
        ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled,
        capture_input: ai_input_capture_callback
      )

      ReceiptAnalysisRuns.record_ai_result(run, ai_result)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, ai_result)

      Result.new(ai_result: ai_result)
    end

    private

    attr_reader :run, :ocr_result, :ai_name_completion_enabled

    def ai_input_capture_callback
      ->(input) { ReceiptAnalysisRuns.record_ai_input(run, input) }
    end
  end
end
