module Receipts
  module Processing
    class AnalysisError < StandardError
      attr_reader :error_code, :metadata

      def initialize(error_code, message = nil, metadata: {})
        @error_code = error_code
        @metadata = metadata.to_h
        super(message)
      end
    end

    Error = Class.new(StandardError)
    InvalidTransition = Class.new(Error)
    TerminalRunError = Class.new(Error)
    EnqueueError = Class.new(Error)

    Result = Struct.new(
      :ocr_result,
      :ai_result,
      :finalize_decision,
      :next_step,
      :skip_reason,
      keyword_init: true
    ) do
      # Provider payload の成否を表す補助。Job の後続enqueue判定は next_step を使う。
      def success?
        result = ai_result || ocr_result

        result&.dig(:success) == true
      end
    end

    StartResult = Struct.new(:run, :created, keyword_init: true) do
      def created?
        created == true
      end
    end

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
        Pipeline.run_ocr(...)
      end

      def run_ai(...)
        Pipeline.run_ai(...)
      end

      def run_finalize(...)
        Pipeline.run_finalize(...)
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
