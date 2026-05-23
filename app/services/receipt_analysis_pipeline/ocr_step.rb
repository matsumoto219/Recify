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
        if ocr_enabled?
          ReceiptOcrService.call(receipt.image)
        else
          Ocr::ResultTemplate.error_result(
            error_code: "ocr_disabled",
            provider: "azure_document_intelligence"
          )
        end

      ReceiptAnalysisRuns.record_ocr_result(run, ocr_result)
      ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result)

      Result.new(ocr_result: ocr_result)
    end

    private

    attr_reader :run, :receipt

    def ocr_enabled?
      ActiveModel::Type::Boolean.new.cast(
        ENV.fetch(Config::OCR_ENABLED_ENV_KEY, "true")
      )
    end
  end
end
