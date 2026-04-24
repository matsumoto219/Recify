# frozen_string_literal: true

module Amounts
  class Resolver
    def initialize(computed:, receipt:, context:)
      @computed = computed
      @receipt = receipt
      @context = context
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
        subtotal: @receipt[:subtotal_amount] || @computed[:subtotal],
        tax: @receipt[:tax_amount] || @computed[:tax],
        total: @receipt[:total_amount] || @computed[:total],
        tax_rate: @receipt[:tax_rate] || @computed[:tax_rate]
      }
    end

    def resolve_edit_save
      {
        subtotal: @computed[:subtotal],
        tax: @computed[:tax],
        total: @computed[:total],
        tax_rate: @computed[:tax_rate]
      }
    end

    def resolve_manual
      resolve_edit_save
    end
  end
end
