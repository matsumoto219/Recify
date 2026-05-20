class ReceiptAnalysisJob < ApplicationJob
  queue_as :receipt_analysis

  discard_on ActiveRecord::RecordNotFound

  # NOTE: OCR/AIはResultで失敗を返す設計のため、Jobのretry_onは現時点では使用しない。
  # 外部API再試行は、再解析機能またはService層のretry方針として別途検討する。
  # TODO: ログ強化（外部API応答・エラー分類の詳細化などは本番運用フェーズで対応）
  def perform(receipt_id)
    receipt = Receipt.find(receipt_id)

    unless receipt.processing?
      Rails.logger.info(
        "[ReceiptAnalysisJob] skipped receipt_id=#{receipt.id} status=#{receipt.status} reason=not_processing"
      )
      return
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      ReceiptAnalysisService.call(receipt)

      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      duration_ms = ((finished_at - started_at) * 1000).round(1)

      Rails.logger.info(
        "[ReceiptAnalysisJob] completed receipt_id=#{receipt.id} duration_ms=#{duration_ms}"
      )
    rescue => e
      Rails.logger.error(
        "[ReceiptAnalysisJob] failed receipt_id=#{receipt.id} error_class=#{e.class} message=#{e.message}"
      )
      raise
    end
  end
end
