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

      if tax_detail_total.positive? && item_tax_total.positive? && tax_detail_total != item_tax_total
        errors << :tax_detail_mismatch
      end

      if @context == :analysis
        if present?(@receipt[:total_amount]) && @receipt[:total_amount].to_i != @resolved[:total].to_i
          errors << :ocr_total_mismatch
        end
      end

      # 税抜/税込混在の可能性検知
      if mixed_tax_inclusion_suspected?
        errors << :price_tax_inclusion_uncertain
      end

      errors.uniq
    end

    private

    def item_tax_total
      @computed[:item_tax_total].to_i
    end

    def tax_detail_total
      @computed[:tax_detail_total].to_i
    end

    def mixed_tax_inclusion_suspected?
      return false unless @context == :analysis

      ocr_total = @receipt[:total_amount].to_i
      resolved_total = @resolved[:total].to_i

      return false if ocr_total == 0 || resolved_total == 0

      # OCRとitems合計がズレている
      mismatch = ocr_total != resolved_total

      # tax mismatchが発生している（内訳もズレている）
      tax_mismatch = (@computed[:tax_detail_total].to_i != @computed[:item_tax_total].to_i)

      # どちらかでも起きていれば「混在の可能性」とみなす
      mismatch && tax_mismatch
    end

    def present?(v)
      !v.nil? && v != ""
    end
  end
end
