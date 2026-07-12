module Receipts
  module Processing
    AnalysisError = ReceiptAnalysisPipeline::AnalysisError
    EnqueueError = ReceiptAnalysisRuns::EnqueueError
    Error = ReceiptAnalysisRuns::Error
    InvalidTransition = ReceiptAnalysisRuns::InvalidTransition
    Result = ReceiptAnalysisPipeline::Result
    StartResult = ReceiptAnalysisRuns::StartResult
    TerminalRunError = ReceiptAnalysisRuns::TerminalRunError

    class << self
      def admin_retry_eligibility(...)
        SystemOperations.receipt_analysis_retry_eligibility(...)
      end

      def admin_retry_types
        SystemOperations.receipt_analysis_retry_types
      end

      def finalize_decision_from_snapshot(snapshot)
        Contracts::FinalizeDecision.from_snapshot(snapshot)
      end

      def run_ocr(...)
        ReceiptAnalysisPipeline.run_ocr(...)
      end

      def run_ai(...)
        ReceiptAnalysisPipeline.run_ai(...)
      end

      def run_finalize(...)
        ReceiptAnalysisPipeline.run_finalize(...)
      end

      def start(...)
        ReceiptAnalysisRuns.start(...)
      end

      def enqueue(...)
        ReceiptAnalysisRuns.enqueue(...)
      end

      def start_stage(...)
        ReceiptAnalysisRuns.start_stage(...)
      end

      def claim_stage(...)
        ReceiptAnalysisRuns.claim_stage(...)
      end

      def external_service_runtime_config(...)
        ReceiptAnalysisRuns.external_service_runtime_config(...)
      end

      def finish_stage(...)
        ReceiptAnalysisRuns.finish_stage(...)
      end

      def record_ocr_result(...)
        ReceiptAnalysisRuns.record_ocr_result(...)
      end

      def record_ocr_snapshot(...)
        ReceiptAnalysisRuns.record_ocr_snapshot(...)
      end

      def record_ocr_response_artifact(...)
        ReceiptAnalysisRuns.record_ocr_response_artifact(...)
      end

      def record_ai_input(...)
        ReceiptAnalysisRuns.record_ai_input(...)
      end

      def record_ai_result(...)
        ReceiptAnalysisRuns.record_ai_result(...)
      end

      def record_ai_normalized_result(...)
        ReceiptAnalysisRuns.record_ai_normalized_result(...)
      end

      def record_finalize_decision(...)
        ReceiptAnalysisRuns.record_finalize_decision(...)
      end

      def record_build_params_snapshot(...)
        ReceiptAnalysisRuns.record_build_params_snapshot(...)
      end

      def record_final_result(...)
        ReceiptAnalysisRuns.record_final_result(...)
      end

      def copy_retry_snapshots(...)
        ReceiptAnalysisRuns.copy_retry_snapshots(...)
      end

      def succeed(...)
        ReceiptAnalysisRuns.succeed(...)
      end

      def fail(...)
        ReceiptAnalysisRuns.fail(...)
      end

      def supersede(...)
        ReceiptAnalysisRuns.supersede(...)
      end

      def cancel(...)
        ReceiptAnalysisRuns.cancel(...)
      end

      def cleanup_stale(...)
        ReceiptAnalysisRuns.cleanup_stale(...)
      end

      def cleanup_expired(...)
        ReceiptAnalysisRuns.cleanup_expired(...)
      end
    end
  end
end
