class ReceiptAiEnrichmentJob < ApplicationJob
  queue_as :receipt_ai

  discard_on ActiveRecord::RecordNotFound

  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    result = Receipts::Processing.run_ai(run)

    Receipts::Processing.enqueue(run, job_class: ReceiptFinalizeJob) if result.next_step == :finalize
  end
end
