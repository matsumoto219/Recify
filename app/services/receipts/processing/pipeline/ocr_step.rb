class Receipts::Processing::Pipeline
  class OcrStep
    def self.call(run, before_provider_call: nil)
      new(run, before_provider_call: before_provider_call).call
    end

    def initialize(run, before_provider_call: nil)
      @run = run
      @receipt = run.receipt
      @before_provider_call = before_provider_call
    end

    def call
      ocr_result =
        if ocr_unavailable?
          ReceiptOcrService.error_result(
            error_code: "ocr_disabled",
            provider: "azure_document_intelligence",
            provider_error_detail: ExternalServices.unavailable_detail(
              :ocr,
              provider: "azure_document_intelligence",
              phase: "preflight"
            )
          )
        else
          ReceiptOcrService.call(
            receipt.image,
            runtime_config: Receipts::Processing.external_service_runtime_config(run).ocr,
            before_provider_call: before_provider_call,
            after_provider_success_response: ocr_response_artifact_callback
          )
        end

      Receipts::Processing.record_ocr_result(run, ocr_result)
      Receipts::Processing.record_ocr_snapshot(run, ocr_result)

      Result.new(ocr_result: ocr_result)
    end

    private

    attr_reader :run, :receipt, :before_provider_call

    def ocr_unavailable?
      ExternalServices.down?(:ocr)
    end

    def ocr_response_artifact_callback
      lambda do |raw_body, response:, provider:|
        Receipts::Processing.record_ocr_response_artifact(
          run,
          raw_body,
          provider: provider,
          model_id: response["modelId"]
        )
      end
    end
  end
end
