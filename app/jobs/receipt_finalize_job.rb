class ReceiptFinalizeJob < ApplicationJob
  queue_as :receipt_finalize

  discard_on ActiveRecord::RecordNotFound

  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    ReceiptAnalysisPipeline.run_finalize(run)
  end
end
