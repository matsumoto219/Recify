class ReceiptOcrJob < ApplicationJob
  queue_as :receipt_ocr

  discard_on ActiveRecord::RecordNotFound

  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    result = ReceiptAnalysisPipeline.run_ocr(run)

    case result.next_step
    when :ai
      ReceiptAiEnrichmentJob.perform_later(run_id: run.id)
    when :finalize
      ReceiptFinalizeJob.perform_later(run_id: run.id)
    end
  end
end
