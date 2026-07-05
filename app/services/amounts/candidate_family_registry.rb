# frozen_string_literal: true

module Amounts
  class CandidateFamilyRegistry
    FAMILIES = %i[
      receipt_input
      incomplete_tax_details_receipt_tax
      item_amounts
      printed_tax_details
      mixed_tax_basis
    ].freeze

    class << self
      def call
        FAMILIES
      end
    end
  end
end
