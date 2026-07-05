# frozen_string_literal: true

module Amounts
  class CandidateProfileResolver
    def initialize(candidate)
      @candidate = candidate
    end

    def receipt_tax_basis
      candidate_profile_basis(:receipt_tax_basis) || legacy_receipt_tax_basis
    end

    def item_amount_basis
      candidate_profile_basis(:item_amount_basis) || legacy_item_amount_basis
    end

    def tax_detail_amount_basis
      candidate_profile_basis(:tax_detail_amount_basis) || legacy_tax_detail_amount_basis
    end

    private

    attr_reader :candidate

    def candidate_profile_basis(key)
      value = candidate_profile_value(key)
      value.to_sym if value.present?
    end

    def candidate_profile_value(key)
      profile = candidate.calculation_profile
      return nil unless profile.respond_to?(:key?)

      profile[key] || profile[key.to_s]
    end

    def legacy_item_amount_basis
      case candidate.basis
      when "external_tax_from_receipt", "items_as_tax_excluded"
        :line_total_as_net
      when "mixed_by_tax_rate_group"
        :mixed_by_tax_rate_group
      else
        :line_total_as_recorded
      end
    end

    def legacy_receipt_tax_basis
      %w[external_tax_from_receipt items_as_tax_excluded printed_tax_details_net].include?(candidate.basis) ? :tax_added_to_subtotal : :total_includes_tax
    end

    def legacy_tax_detail_amount_basis
      case candidate.basis
      when "printed_tax_details_gross"
        :gross
      when "printed_tax_details_net", "external_tax_from_receipt", "items_as_tax_excluded"
        :net
      else
        :unknown
      end
    end
  end
end
