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

    Result = Data.define(
      :ocr_result,
      :ai_result,
      :finalize_decision,
      :next_step,
      :skip_reason
    ) do
      def initialize(ocr_result: nil, ai_result: nil, finalize_decision: nil, next_step: nil, skip_reason: nil)
        super(ocr_result:, ai_result:, finalize_decision:, next_step:, skip_reason:)
      end

      # Provider payload の成否を表す補助。Job の後続enqueue判定は next_step を使う。
      def success?
        result = ai_result || ocr_result

        result&.dig(:success) == true
      end
    end

    StartResult = Data.define(:run, :created) do
      def initialize(run:, created:)
        super(run:, created:)
      end

      def created?
        created == true
      end
    end

    class << self
      def admin_retry_eligibility(...)
        AdminRetryPolicy.eligibility(...)
      end

      def admin_retry_types
        AdminRetryPolicy::RETRY_TYPES
      end

      def admin_retry_decision(...)
        AdminRetryPolicy.decision(...)
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

      def mark_processing!(receipt)
        StatusTransition.mark_processing!(receipt)
      end

      def start(...)
        Runs.start(...)
      end

      def enqueue(...)
        Runs.enqueue(...)
      end

      def start_stage(...)
        Runs.start_stage(...)
      end

      def claim_stage(...)
        Runs.claim_stage(...)
      end

      def external_service_runtime_config(...)
        Runs.external_service_runtime_config(...)
      end

      def finish_stage(...)
        Runs.finish_stage(...)
      end

      def record_ocr_result(...)
        Runs.record_ocr_result(...)
      end

      def record_ocr_snapshot(...)
        Runs.record_ocr_snapshot(...)
      end

      def record_ocr_response_artifact(...)
        Runs.record_ocr_response_artifact(...)
      end

      def record_ai_input(...)
        Runs.record_ai_input(...)
      end

      def record_ai_result(...)
        Runs.record_ai_result(...)
      end

      def record_ai_normalized_result(...)
        Runs.record_ai_normalized_result(...)
      end

      def record_finalize_decision(...)
        Runs.record_finalize_decision(...)
      end

      def record_build_params_snapshot(...)
        Runs.record_build_params_snapshot(...)
      end

      def record_final_result(...)
        Runs.record_final_result(...)
      end

      def copy_retry_snapshots(...)
        Runs.copy_retry_snapshots(...)
      end

      def succeed(...)
        Runs.succeed(...)
      end

      def fail(...)
        Runs.fail(...)
      end

      def supersede(...)
        Runs.supersede(...)
      end

      def cancel(...)
        Runs.cancel(...)
      end

      def cleanup_stale(...)
        Runs.cleanup_stale(...)
      end

      def cleanup_expired(...)
        Runs.cleanup_expired(...)
      end
    end
  end
end
