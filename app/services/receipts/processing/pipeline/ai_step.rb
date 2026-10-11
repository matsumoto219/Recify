class Receipts::Processing::Pipeline
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
      @requested_ai_name_completion_enabled = ai_name_completion_enabled == true
      @before_provider_call = before_provider_call
    end

    def call
      ai_result =
        if ai_unavailable?
          ReceiptAiEnrichmentService.error_result(
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
            runtime_config: runtime_config,
            capture_input: ai_input_capture_callback,
            before_provider_call: before_provider_call
          )
        end

      Receipts::Processing.record_ai_result(run, ai_result)
      Receipts::Processing.record_ai_normalized_result(run, ai_result)

      Receipts::Processing::Result.new(ai_result: ai_result)
    end

    private

    attr_reader :run, :ocr_result, :requested_ai_name_completion_enabled, :before_provider_call

    def runtime_config
      @runtime_config ||= Receipts::Processing.external_service_runtime_config(run).ai
    end

    def ai_name_completion_enabled
      return @ai_name_completion_enabled if defined?(@ai_name_completion_enabled)

      meta = run.ai_input_snapshot.to_h["meta"].to_h
      return @ai_name_completion_enabled = requested_ai_name_completion_enabled unless meta.key?("ai_execution")

      enabled = meta["ai_name_completion_enabled"]
      unless [ true, false ].include?(enabled) && meta["ai_execution"] == ai_execution_snapshot(enabled)
        raise ExternalServices::RuntimeConfigUnavailableError
      end

      @ai_name_completion_enabled = enabled
    end

    def ai_execution_snapshot(enabled = ai_name_completion_enabled)
      {
        "schema_version" => 1,
        "model" => runtime_config.model,
        "reasoning_effort" => enabled ? runtime_config.name_completion_reasoning_effort : runtime_config.reasoning_effort
      }
    end

    def ai_input_capture_callback
      lambda do |input|
        snapshot_input = input.deep_merge(meta: {
          ai_name_completion_enabled: ai_name_completion_enabled,
          ai_execution: ai_execution_snapshot
        })
        Receipts::Processing.record_ai_input(run, snapshot_input)
      end
    end

    def ai_unavailable?
      ExternalServices.down?(:ai)
    end
  end
end
