# frozen_string_literal: true

module Amounts
  class HardRejector
    ITEM_GROSS_MISMATCH_RATIO = BigDecimal("0.20")
    ITEM_GROSS_MISMATCH_MIN = 100

    def initialize(receipt:, items:, tax_details:, payments:)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @payments = Array(payments)
      @detected_tax_details = Amounts::TaxDetailBasisDetector.call(@tax_details)
    end

    def call(candidate)
      reasons = []
      reasons << :invalid_amount_relation unless valid_amount_relation?(candidate)
      reasons << :tax_details_double_counted if tax_details_double_counted?(candidate)
      reasons << :tax_detail_gross_item_mismatch if tax_detail_gross_item_mismatch?(candidate)
      reasons << :tax_detail_gross_item_mismatch if external_tax_item_net_mismatch?(candidate)

      candidate.with_hard_reject_reasons(reasons)
    end

    private

    attr_reader :receipt, :items, :tax_details, :payments, :detected_tax_details

    def valid_amount_relation?(candidate)
      return true if candidate.basis == "receipt_input_preserved"
      return true if gross_tax_detail_amount_basis?(candidate)

      candidate.subtotal.to_i + candidate.tax.to_i == candidate.purchase_total.to_i
    end

    def tax_details_double_counted?(candidate)
      return false unless duplicate_or_intermediate_tax_details?
      return true if candidate.basis == "printed_tax_details_raw_sum"

      false
    end

    def duplicate_or_intermediate_tax_details?
      detected_tax_details.any? { |detail| detail[:basis] == :intermediate } ||
        detected_tax_details.group_by { |detail| detail[:rate] }.any? do |rate, details|
          rate.positive? && details.count { |detail| detail[:net_amount].to_i.positive? && detail[:amount].to_i.positive? } > 1
      end
    end

    def tax_detail_gross_item_mismatch?(candidate)
      return false unless candidate.basis.start_with?("printed_tax_details") || candidate.basis == "external_tax_from_receipt"
      return false unless item_gross_sum.positive?

      comparable_item_total = adjusted_item_total(candidate)
      expected_total = tax_detail_item_comparison_total(candidate)
      delta = (expected_total - comparable_item_total).abs
      threshold = [ ITEM_GROSS_MISMATCH_MIN, (BigDecimal(comparable_item_total.to_s) * ITEM_GROSS_MISMATCH_RATIO).to_i ].max

      delta > threshold
    end

    def external_tax_item_net_mismatch?(candidate)
      return false unless candidate.basis == "external_tax_from_receipt"
      return false unless item_gross_sum.positive?

      expected_net = source_adjusted_item_total(candidate)
      expected_net != candidate.subtotal.to_i
    end

    def tax_detail_item_comparison_total(candidate)
      if candidate.basis == "external_tax_from_receipt" || candidate.basis == "printed_tax_details_net"
        candidate.subtotal.to_i
      else
        candidate.purchase_total.to_i
      end
    end

    def gross_tax_detail_amount_basis?(candidate)
      candidate.basis == "printed_tax_details_gross" ||
        candidate_profile_value(candidate, :tax_detail_amount_basis).to_s == "gross"
    end

    def candidate_profile_value(candidate, key)
      profile = candidate.calculation_profile
      return nil unless profile.respond_to?(:key?)

      profile[key] || profile[key.to_s]
    end

    def adjusted_item_total(candidate)
      [ candidate_item_total(candidate) + candidate.purchase_adjustment_total.to_i, 0 ].max
    end

    def source_adjusted_item_total(candidate)
      [ item_gross_sum + candidate.purchase_adjustment_total.to_i, 0 ].max
    end

    def item_gross_sum
      @item_gross_sum ||= items.sum { |item| item_line_total(item) }
    end

    def candidate_item_total(candidate)
      Array(candidate.computed_items).sum { |item| item_line_total(item) }
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return Amounts::NumberParser.parse_amount(line_total) if present?(line_total)

      price = Amounts::NumberParser.parse_amount(fetch_value(item, :price))
      quantity = Amounts::NumberParser.parse_quantity(fetch_value(item, :quantity))
      unit = fetch_value(item, :quantity_unit).to_s.strip
      return 0 unless defined?(ReceiptItem::COUNTABLE_QUANTITY_UNITS) && ReceiptItem::COUNTABLE_QUANTITY_UNITS.include?(unit)

      BigDecimal(price.to_s).*(quantity.positive? ? quantity : BigDecimal("1")).round(0).to_i
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)

        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end

    def present?(value)
      !value.nil? && value != ""
    end
  end
end
