module Receipts
  module Processing
    class << self
      def admin_retry_eligibility(...)
        Analysis.retry_eligibility(...)
      end

      def admin_retry_types
        Analysis.retry_types
      end

      def finalize_decision_from_snapshot(snapshot)
        Contracts::FinalizeDecision.from_snapshot(snapshot)
      end
    end
  end
end
