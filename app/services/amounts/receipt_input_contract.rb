# frozen_string_literal: true

module Amounts
  class ReceiptInputContract
    SUBMISSION_FLAG_KEYS = %i[
      amount_subtotal_amount_submitted
      amount_tax_amount_submitted
      amount_total_amount_submitted
      amount_tax_rate_submitted
    ].freeze
    AMOUNT_KEYS = %i[
      subtotal_amount
      tax_amount
      total_amount
    ].freeze

    def self.amount_relation_required?(candidate:, receipt:, items:, tax_details:)
      new(
        candidate: candidate,
        receipt: receipt,
        items: items,
        tax_details: tax_details
      ).amount_relation_required?
    end

    def initialize(candidate:, receipt:, items:, tax_details:)
      @candidate = candidate
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
    end

    def amount_relation_required?
      return true unless candidate.basis == "receipt_input_preserved"
      return false if input_submission_flags_present? && submission_flags.none?
      return false if items.empty? && tax_details.empty? && incomplete_amount_input?

      true
    end

    private

    attr_reader :candidate, :receipt, :items, :tax_details

    def input_submission_flags_present?
      submission_flags.all? { |flag| flag == true || flag == false }
    end

    def submission_flags
      @submission_flags ||= SUBMISSION_FLAG_KEYS.map { |key| fetch_value(receipt, key) }
    end

    def incomplete_amount_input?
      AMOUNT_KEYS.any? { |key| !present?(fetch_value(receipt, key)) }
    end

    def fetch_value(value, key)
      if value.respond_to?(:key?)
        return value[key] if value.key?(key)
        return value[key.to_s] if value.key?(key.to_s)
      elsif value.respond_to?(key)
        return value.public_send(key)
      end

      nil
    end

    def present?(value)
      !value.nil? && value != ""
    end
  end
end
