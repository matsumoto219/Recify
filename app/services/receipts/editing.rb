module Receipts
  module Editing
    class ConflictError < StandardError
      attr_reader :attributes_key, :duplicate_ids

      def initialize(attributes_key:, duplicate_ids:)
        @attributes_key = attributes_key
        @duplicate_ids = duplicate_ids
        super("Duplicate nested child ids for #{attributes_key}")
      end
    end

    class << self
      def build_input(...)
        InputBuilder.call(...)
      end

      def change_set(...)
        ChangeSet.call(...)
      end

      def check_consistency(...)
        ConsistencyGuard.call(...)
      end

      def apply_amount_result!(...)
        AmountResultApplicator.call(...)
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
