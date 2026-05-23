class ReceiptAnalysisPipeline
  LOG_TAG = "[ReceiptAnalysisJob]".freeze

  class << self
    def run_current_pipeline(run)
      new(run).run_current_pipeline
    end
  end

  def initialize(run)
    @run = run
    @receipt = run.receipt
  end

  def run_current_pipeline
    if terminal_run?
      Rails.logger.info(
        "#{LOG_TAG} skipped receipt_id=#{receipt.id} run_id=#{run.id} status=#{run.status} reason=terminal_run"
      )
      return
    end

    unless receipt.processing?
      cancel_active_run
      Rails.logger.info(
        "#{LOG_TAG} skipped receipt_id=#{receipt.id} run_id=#{run.id} status=#{receipt.status} reason=not_processing"
      )
      return
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      ReceiptAnalysisRuns.start_stage(run, "ocr")
      ocr_step_result = OcrStep.call(run)
      ReceiptAnalysisService.call(receipt, run: run, ocr_result: ocr_step_result.ocr_result)
      receipt.reload
      ReceiptAnalysisRuns.record_final_result(run, receipt: receipt)
      ReceiptAnalysisRuns.succeed(run)

      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      duration_ms = ((finished_at - started_at) * 1000).round(1)

      Rails.logger.info(
        "#{LOG_TAG} completed receipt_id=#{receipt.id} run_id=#{run.id} duration_ms=#{duration_ms}"
      )
    rescue => e
      fail_run(e)
      Rails.logger.error(
        "#{LOG_TAG} failed receipt_id=#{receipt.id} run_id=#{run.id} error_class=#{e.class} message=#{e.message}"
      )
      raise
    end
  end

  private

  attr_reader :run, :receipt

  def terminal_run?
    !ReceiptAnalysisRun::ACTIVE_STATUSES.include?(run.status)
  end

  def cancel_active_run
    return unless run.active?

    ReceiptAnalysisRuns.cancel(run)
  rescue ReceiptAnalysisRuns::TerminalRunError
    nil
  end

  def fail_run(error)
    ReceiptAnalysisRuns.fail(
      run,
      error_stage: run.stage.presence || "ocr",
      error_code: error_code_for(error),
      error_message: error.message
    )
  rescue ReceiptAnalysisRuns::TerminalRunError
    nil
  end

  def error_code_for(error)
    return error.error_code if error.respond_to?(:error_code) && error.error_code.present?

    "unexpected_error"
  end
end
