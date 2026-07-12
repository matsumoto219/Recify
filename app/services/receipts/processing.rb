module Receipts
  module Processing
    class << self
      def finalize_decision_from_snapshot(snapshot)
        Contracts::FinalizeDecision.from_snapshot(snapshot)
      end
    end
  end
end
