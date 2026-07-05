# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class ItemAmounts < Base
      def call
        delegate(:item_candidates)
      end
    end
  end
end
