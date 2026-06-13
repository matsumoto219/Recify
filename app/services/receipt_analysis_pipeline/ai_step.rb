class ReceiptAnalysisPipeline
  class AiStep
    def self.call(run:, ocr_result:, ai_name_completion_enabled: false, before_provider_call: nil)
      new(
        run: run,
        ocr_result: ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled,
        before_provider_call: before_provider_call
      ).call
    end

    def initialize(run:, ocr_result:, ai_name_completion_enabled: false, before_provider_call: nil)
      @run = run
      @ocr_result = ocr_result
      @ai_name_completion_enabled = ai_name_completion_enabled == true
      @before_provider_call = before_provider_call
    end

    def call
      ReceiptAnalysisRuns.start_stage(run, "ai")

      ai_result =
        if ai_unavailable?
          Ai::ResultTemplate.error(
            error_code: "ai_unavailable",
            review_reasons: [ "ai_unavailable" ],
            meta: {
              final_error_detail: ExternalServices.unavailable_detail(:ai, phase: "preflight")
            }.compact
          )
        else
          ReceiptAiEnrichmentService.call(
            ocr_result,
            ai_name_completion_enabled: ai_name_completion_enabled,
            capture_input: ai_input_capture_callback,
            before_provider_call: before_provider_call
          )
        end

      ReceiptAnalysisRuns.record_ai_result(run, ai_result)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, ai_result)

      Result.new(ai_result: ai_result)
    end

    private

    attr_reader :run, :ocr_result, :ai_name_completion_enabled, :before_provider_call

    def ai_input_capture_callback
      ->(input) { ReceiptAnalysisRuns.record_ai_input(run, input) }
    end

    def ai_unavailable?
      ExternalServices.down?(:ai)
    end
  end
end
