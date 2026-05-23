class ReceiptAnalysisJob < ApplicationJob
  queue_as :receipt_analysis

  discard_on ActiveRecord::RecordNotFound

  LEGACY_RUN_SOURCE = "system_retry"

  # NOTE: OCR/AIはResultで失敗を返す設計のため、Jobのretry_onは現時点では使用しない。
  # 外部API再試行は、再解析機能またはService層のretry方針として別途検討する。
  # TODO: ログ強化（外部API応答・エラー分類の詳細化などは本番運用フェーズで対応）
  def perform(receipt_id = nil, run_id: nil)
    run = run_id.present? ? ReceiptAnalysisRun.find(run_id) : nil
    receipt = run&.receipt || Receipt.find(receipt_id)

    if terminal_run?(run)
      Rails.logger.info(
        "[ReceiptAnalysisJob] skipped receipt_id=#{receipt.id} run_id=#{run.id} status=#{run.status} reason=terminal_run"
      )
      return
    end

    unless receipt.processing?
      cancel_active_run(run)
      Rails.logger.info(
        "[ReceiptAnalysisJob] skipped receipt_id=#{receipt.id} run_id=#{run&.id} status=#{receipt.status} reason=not_processing"
      )
      return
    end

    run ||= active_run_for(receipt) || start_legacy_run(receipt)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      ReceiptAnalysisRuns.start_stage(run, "ocr")
      ReceiptAnalysisService.call(receipt)
      receipt.reload
      ReceiptAnalysisRuns.record_final_result(run, receipt: receipt)
      ReceiptAnalysisRuns.succeed(run)

      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      duration_ms = ((finished_at - started_at) * 1000).round(1)

      Rails.logger.info(
        "[ReceiptAnalysisJob] completed receipt_id=#{receipt.id} run_id=#{run.id} duration_ms=#{duration_ms}"
      )
    rescue => e
      fail_run(run, e)
      Rails.logger.error(
        "[ReceiptAnalysisJob] failed receipt_id=#{receipt.id} run_id=#{run.id} error_class=#{e.class} message=#{e.message}"
      )
      raise
    end
  end

  private

  def active_run_for(receipt)
    receipt.receipt_analysis_runs.active.order(created_at: :desc).first
  end

  def start_legacy_run(receipt)
    # TODO: 次コミットで旧 receipt_id 経路を削除し、run_id: のみにする。
    ReceiptAnalysisRuns.start(receipt: receipt, source: LEGACY_RUN_SOURCE).run
  end

  def terminal_run?(run)
    run.present? && !ReceiptAnalysisRun::ACTIVE_STATUSES.include?(run.status)
  end

  def cancel_active_run(run)
    return unless run&.active?

    ReceiptAnalysisRuns.cancel(run)
  rescue ReceiptAnalysisRuns::TerminalRunError
    nil
  end

  def fail_run(run, error)
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
