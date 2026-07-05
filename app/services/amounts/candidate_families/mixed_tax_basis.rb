# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class MixedTaxBasis < Base
      def call
        delegate(:mixed_candidates)
      end
    end
  end
end
