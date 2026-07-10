# frozen_string_literal: true

module Amounts
  class AdjustmentTaxRateResolver
    class << self
      def call(adjustments:, items:, tax_details:)
        new(adjustments: adjustments, items: items, tax_details: tax_details).call
      end
    end

    def initialize(adjustments:, items:, tax_details:)
      @adjustments = Array(adjustments)
      @items = Array(items)
      @tax_details = Array(tax_details)
    end

    def call
      adjustments.map { |adjustment| resolve(adjustment) }
    end

    private

    attr_reader :adjustments, :items, :tax_details

    def resolve(adjustment)
      normalized = normalize_adjustment(adjustment)
      if payment_adjustment?(normalized)
        return normalized.merge(tax_rate: nil, tax_rate_present: false, tax_rate_source: "not_applicable")
      end
      return normalized.merge(tax_rate_source: "explicit") if normalized[:tax_rate_present]

      inherited_rate = safely_inherited_rate
      return normalized.merge(tax_rate: nil, tax_rate_present: false, tax_rate_source: "unknown") unless inherited_rate

      normalized.merge(
        tax_rate: inherited_rate,
        tax_rate_present: true,
        tax_rate_source: "inherited_single_rate"
      )
    end

    def payment_adjustment?(adjustment)
      Amounts::AdjustmentClassifier.payment_adjustment?(adjustment)
    end

    def normalize_adjustment(adjustment)
      normalized = adjustment.to_h.symbolize_keys
      tax_rate_present =
        if normalized.key?(:tax_rate_present)
          normalized[:tax_rate_present] == true
        else
          !normalized[:tax_rate].nil? && normalized[:tax_rate] != ""
        end

      normalized.merge(tax_rate_present: tax_rate_present)
    end

    def safely_inherited_rate
      @safely_inherited_rate ||= begin
        item_rates = amount_bearing_item_rates
        rate = item_rates.one? && item_rates.first&.positive? ? item_rates.first : nil

        rate if rate && tax_details_compatible_with?(rate)
      end
    end

    def amount_bearing_item_rates
      amount_bearing_items = items.select { |item| item_amount(item).positive? }
      return [] if amount_bearing_items.blank?

      rates = amount_bearing_items.map { |item| parse_rate(fetch_value(item, :tax_rate)) }
      return [] if rates.any?(&:nil?)

      rates.uniq
    end

    def tax_details_compatible_with?(rate)
      relevant_details = tax_details.select { |detail| tax_detail_amount(detail).positive? }
      return true if relevant_details.blank?

      detail_rates = relevant_details.map { |detail| parse_rate(fetch_value(detail, :rate)) }
      detail_rates.none?(&:nil?) && detail_rates.uniq == [ rate ]
    end

    def item_amount(item)
      line_total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(item, :line_total))
      return line_total.abs if line_total

      price = Amounts::NumberParser.parse_amount(fetch_value(item, :price))
      quantity = Amounts::NumberParser.parse_quantity(fetch_value(item, :quantity), default: BigDecimal("1"))
      (BigDecimal(price.to_s) * quantity).round(0).to_i.abs
    end

    def tax_detail_amount(detail)
      amount = Amounts::NumberParser.parse_amount(fetch_value(detail, :amount))
      net_amount = Amounts::NumberParser.parse_amount(fetch_value(detail, :net_amount))
      amount.abs + net_amount.abs
    end

    def parse_rate(value)
      return nil if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      nil
    end

    def fetch_value(object, key)
      return object[key] if object.respond_to?(:key?) && object.key?(key)
      return object[key.to_s] if object.respond_to?(:key?) && object.key?(key.to_s)

      object.public_send(key) if object.respond_to?(key)
    end
  end
end
