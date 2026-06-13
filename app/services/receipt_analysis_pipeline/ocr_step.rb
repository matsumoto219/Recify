class ReceiptAnalysisPipeline
  class OcrStep
    def self.call(run)
      new(run).call
    end

    def initialize(run)
      @run = run
      @receipt = run.receipt
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
          ReceiptOcrService.call(receipt.image)
        end

      ReceiptAnalysisRuns.record_ocr_result(run, ocr_result)
      ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result)

      Result.new(ocr_result: ocr_result)
    end

    private

    attr_reader :run, :receipt

    def ocr_unavailable?
      ExternalServices.down?(:ocr)
    end
  end
end
