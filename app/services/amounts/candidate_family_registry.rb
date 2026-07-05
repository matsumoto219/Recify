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
    FAMILY_CLASSES = {
      receipt_input: Amounts::CandidateFamilies::ReceiptInput,
      incomplete_tax_details_receipt_tax: Amounts::CandidateFamilies::IncompleteTaxDetailsReceiptTax,
      item_amounts: Amounts::CandidateFamilies::ItemAmounts,
      printed_tax_details: Amounts::CandidateFamilies::PrintedTaxDetails,
      mixed_tax_basis: Amounts::CandidateFamilies::MixedTaxBasis
    }.freeze

    class << self
      def call
        FAMILIES
      end

      def build(family, generator)
        FAMILY_CLASSES.fetch(family.to_sym).new(generator).call
      end
    end
  end
end
