class ReceiptOcrJob < ApplicationJob
  queue_as :receipt_ocr

  discard_on ActiveRecord::RecordNotFound

  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    result = Receipts::Processing.run_ocr(run)

    case result.next_step
    when :ai
      Receipts::Processing.enqueue(run, job_class: ReceiptAiEnrichmentJob)
    when :finalize
      Receipts::Processing.enqueue(run, job_class: ReceiptFinalizeJob)
    end
  end
end
