class ReceiptFinalizeJob < ApplicationJob
  RETRYABLE_ERRORS = [ Receipts::Processing::RetryableFinalizeError ].freeze

  queue_as :receipt_finalize

  discard_on ActiveRecord::RecordNotFound
  retry_on(*RETRYABLE_ERRORS,
    wait: :polynomially_longer,
    attempts: 3,
    jitter: 0.15)

  after_discard do |job, error|
    next unless RETRYABLE_ERRORS.any? { |error_class| error.is_a?(error_class) }

    run_id = job.arguments.first.to_h.with_indifferent_access[:run_id]
    run = ReceiptAnalysisRun.find_by(id: run_id)
    next unless run&.active?

    Receipts::Processing.fail(
      run,
      error_stage: "finalize",
      error_code: "unexpected_error",
      error_message: nil
    )
  rescue Receipts::Processing::TerminalRunError
    nil
  end

  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    Receipts::Processing.run_finalize(run)
  end
end
