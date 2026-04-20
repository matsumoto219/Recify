# frozen_string_literal: true

module Amounts
  class Calculator
    def initialize(receipt:, items:, tax_details:)
      @receipt = receipt
      @items = items
      @tax_details = tax_details
    end

    def call
      item_total = calculate_item_total
      tax_total  = calculate_tax_total

      subtotal = resolve_subtotal(item_total)
      tax      = resolve_tax(tax_total, subtotal)
      total    = resolve_total(subtotal, tax)

      {
        item_total: item_total,
        tax_total: tax_total,
        subtotal: subtotal,
        tax: tax,
        total: total
      }
    end

    private

    # -----------------------------
    # Item calculations
    # -----------------------------
    def calculate_item_total
      @items.sum do |item|
        if item[:line_total].to_i > 0
          item[:line_total].to_i
        else
          price = item[:price].to_i
          quantity = item[:quantity].to_i
          quantity = 1 if quantity <= 0
          price * quantity
        end
      end
    end

    # -----------------------------
    # Tax calculations
    # -----------------------------
    def calculate_tax_total
      @tax_details.sum { |t| t[:amount].to_i }
    end

    # -----------------------------
    # Resolve helpers
    # -----------------------------
    def resolve_subtotal(item_total)
      @receipt[:subtotal_amount] || item_total
    end

    def resolve_tax(tax_total, subtotal)
      return @receipt[:tax_amount] if present?(@receipt[:tax_amount])

      return tax_total if tax_total > 0

      if present?(@receipt[:total_amount]) && present?(subtotal)
        tax = @receipt[:total_amount].to_i - subtotal.to_i
        tax = 0 if tax < 0
        tax
      else
        0
      end
    end

    def resolve_total(subtotal, tax)
      return @receipt[:total_amount] if present?(@receipt[:total_amount])

      subtotal.to_i + tax.to_i
    end

    def present?(v)
      !v.nil? && v != ""
    end
  end
end
