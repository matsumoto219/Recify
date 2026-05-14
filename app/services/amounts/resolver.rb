# frozen_string_literal: true

module Amounts
  class Resolver
    def initialize(computed:, receipt:, context:, items: [], tax_details: [])
      @computed = computed
      @receipt = receipt
      @context = normalize_context(context)
      @items = Array(items)
      @tax_details = Array(tax_details)
    end

    def call
      case @context
      when :analysis
        resolve_analysis
      when :edit_save
        resolve_edit_save
      when :manual
        resolve_manual
      else
        resolve_analysis
      end
    end

    private

    def resolve_analysis
      {
        subtotal: @computed[:subtotal],
        tax: @computed[:tax],
        total: @computed[:total],
        tax_rate: @computed[:tax_rate]
      }
    end

    def resolve_edit_save
      return resolve_analysis if item_data_present?

      resolve_receipt_input
    end

    def resolve_manual
      return resolve_analysis if item_data_present?

      resolve_receipt_input
    end

    def resolve_receipt_input
      {
        subtotal: receipt_value(:subtotal_amount, fallback: @computed[:subtotal]),
        tax: receipt_value(:tax_amount, fallback: @computed[:tax]),
        total: receipt_value(:total_amount, fallback: @computed[:total]),
        tax_rate: receipt_value(:tax_rate, fallback: @computed[:tax_rate])
      }
    end

    def item_data_present?
      @items.any? { |item| item_line_total(item).positive? }
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if present?(line_total)

      price = to_amount_decimal(fetch_value(item, :price))
      quantity = to_decimal(fetch_value(item, :quantity))
      quantity = BigDecimal("1") if quantity <= 0

      round_amount(price * quantity)
    end

    def receipt_value(key, fallback:)
      value = fetch_value(@receipt, key)
      return fallback unless present?(value)

      key == :tax_rate ? value : to_i(value)
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(:[])
        value = object[key]
        return value unless value.nil?

        string_value = object[key.to_s]
        return string_value unless string_value.nil?
      elsif object.respond_to?(key)
        return object.public_send(key)
      end
    end

    def to_decimal(value)
      Amounts::NumberParser.parse_quantity(value)
    end

    def to_amount_decimal(value)
      BigDecimal(to_i(value).to_s)
    end

    def round_amount(value)
      BigDecimal(value.to_s).round(0).to_i
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def normalize_context(value)
      context = value.to_s.to_sym
      %i[analysis edit_save manual].include?(context) ? context : :analysis
    end
  end
end
