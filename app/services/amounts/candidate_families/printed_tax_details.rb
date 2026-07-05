# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class PrintedTaxDetails < Base
      def call
        delegate(:printed_tax_detail_candidates)
      end
    end
  end
end
