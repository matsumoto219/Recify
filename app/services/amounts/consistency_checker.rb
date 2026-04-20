# frozen_string_literal: true

module Amounts
  class ConsistencyChecker
    def initialize(computed:, resolved:, item_total:, tax_total:, receipt:, context:)
      @computed = computed
      @resolved = resolved
      @item_total = item_total
      @tax_total = tax_total
      @receipt = receipt
      @context = context
    end

    def call
      errors = []

      if @resolved[:subtotal].to_i + @resolved[:tax].to_i != @resolved[:total].to_i
        errors << :total_mismatch
      end

      if @item_total.to_i != @resolved[:total].to_i
        errors << :item_total_mismatch
      end

      if @tax_total > 0 && @tax_total.to_i != @resolved[:tax].to_i
        errors << :tax_amount_mismatch
      end

      if @context == :analysis
        if present?(@receipt[:total_amount]) && @receipt[:total_amount].to_i != @resolved[:total].to_i
          errors << :ocr_total_mismatch
        end
      end

      errors.uniq
    end

    private

    def present?(v)
      !v.nil? && v != ""
    end
  end
end
