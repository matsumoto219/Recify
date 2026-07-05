# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class IncompleteTaxDetailsReceiptTax < Base
      def call
        delegate(:incomplete_tax_details_receipt_tax_candidate)
      end
    end
  end
end
