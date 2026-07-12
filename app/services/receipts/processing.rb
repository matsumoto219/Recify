module Receipts
  module Processing
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
    end
  end
end
