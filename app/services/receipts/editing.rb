module Receipts
  module Editing
    class << self
      def change_set(...)
        ChangeSet.call(...)
      end

      def check_consistency(...)
        ConsistencyGuard.call(...)
      end

      def review_state(...)
        ReviewState.call(...)
      end

      def item_review_state(...)
        ReviewState.item_review_state(...)
      end
    end
  end
end
