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
      line_total = fetch_value(item, :line_total).to_i
      return line_total if line_total.positive?

      price = fetch_value(item, :price).to_i
      quantity = fetch_value(item, :quantity).to_i
      quantity = 1 if quantity <= 0

      price * quantity
    end

    def receipt_value(key, fallback:)
      value = fetch_value(@receipt, key)
      present?(value) ? value : fallback
    end

    def fetch_value(object, key)
      if object.respond_to?(:[])
        object[key] || object[key.to_s]
      elsif object.respond_to?(key)
        object.public_send(key)
      end
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
