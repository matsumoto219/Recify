class ReceiptAnalysisJob < ApplicationJob
  queue_as :receipt_analysis

  discard_on ActiveRecord::RecordNotFound

  # NOTE: OCR/AIはResultで失敗を返す設計のため、Jobのretry_onは現時点では使用しない。
  # 外部API再試行は、再解析機能またはService層のretry方針として別途検討する。
  # TODO: ログ強化（外部API応答・エラー分類の詳細化などは本番運用フェーズで対応）
  def perform(run_id:)
    run = ReceiptAnalysisRun.find(run_id)
    ReceiptAnalysisPipeline.run_current_pipeline(run)
  end
end
