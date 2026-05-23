class ReceiptAiEnrichmentJob < ApplicationJob
  queue_as :receipt_ai

  discard_on ActiveRecord::RecordNotFound

  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    result = ReceiptAnalysisPipeline.run_ai(run)

    ReceiptFinalizeJob.perform_later(run_id: run.id) if result.next_step == :finalize
  end
end
