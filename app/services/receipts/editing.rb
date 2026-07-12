module Receipts
  module Editing
    class << self
      def change_set(...)
        ReceiptEditSaveChangeSet.call(...)
      end

      def check_consistency(...)
        ReceiptEditSaveConsistencyGuard.call(...)
      end

      def review_state(...)
        ReceiptEditSaveReviewState.call(...)
      end

      def item_review_state(...)
        ReceiptEditSaveReviewState.item_review_state(...)
      end
    end
  end
end
