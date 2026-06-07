# frozen_string_literal: true

module Amounts
  module MismatchSeverity
    BLOCKING = %i[
      total_mismatch
      total_amount_mismatch
      subtotal_amount_mismatch
      item_total_mismatch
      tax_amount_mismatch
      tax_detail_mismatch
      invalid_amount_relation
      payment_amount_mismatch
      tax_details_double_counted
      tax_detail_gross_item_mismatch
      adjustment_uncertain
      insufficient_data
    ].freeze

    WARNING = %i[
      ocr_total_mismatch
      tax_detail_rate_mismatch
      tax_detail_incomplete
      tax_detail_partial
      item_tax_rate_group_uncertain
      zero_amount_item_incomplete
      discount_data_incomplete
      adjustment_tax_rate_missing
      price_tax_inclusion_uncertain
      calculation_profile_uncertain
    ].freeze

    module_function

    def severity(symbol)
      normalized = normalize(symbol)
      return :blocking if BLOCKING.include?(normalized)
      return :warning if WARNING.include?(normalized)

      :blocking
    end

    def blocking?(symbol)
      severity(symbol) == :blocking
    end

    def warning?(symbol)
      severity(symbol) == :warning
    end

    def blocking(inconsistencies)
      Array(inconsistencies).select { |inconsistency| blocking?(inconsistency) }
    end

    def warning(inconsistencies)
      Array(inconsistencies).select { |inconsistency| warning?(inconsistency) }
    end

    def needs_review?(inconsistencies)
      blocking(inconsistencies).any?
    end

    def normalize(symbol)
      symbol.to_s.to_sym
    end
  end
end
