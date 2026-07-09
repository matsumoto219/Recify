# frozen_string_literal: true

require "bigdecimal"

module GeneratedReceipts
  class Comparator
    Result = Struct.new(:case_id, :status, :diffs, keyword_init: true) do
      def pass?
        status == "PASS"
      end
    end
    FAIL_PATHS = %w[
      subtotal
      tax
      total
      tax_rate
      tax_details
      receipt_adjustments
      payment_method
      payments
      processing_error_code
    ].freeze

    class << self
      def call(case_data, actual)
        new(case_data, actual).call
      end

      def snapshot_from_receipt(receipt)
        {
          "store_name" => receipt.store_name,
          "subtotal" => receipt.subtotal_amount&.to_i,
          "tax" => receipt.tax_amount&.to_i,
          "total" => receipt.total_amount&.to_i,
          "tax_rate" => receipt.tax_rate&.to_s,
          "tax_details" => receipt.receipt_tax_details.order(:id).map do |detail|
            net = detail.net_amount&.to_i
            tax = detail.amount&.to_i
            {
              "rate" => detail.rate&.to_s,
              "net" => net,
              "tax" => tax,
              "gross" => net && tax ? net + tax : nil
            }
          end,
          "items" => receipt.receipt_items.order(:position_index, :id).map do |item|
            {
              "name" => item.confirmed_name.presence || item.suggested_name || item.raw_text,
              "line_total" => item.line_total&.to_i,
              "tax_rate" => item.tax_rate&.to_s,
              "discount_amount" => item.discount_amount&.to_i
            }
          end,
          "receipt_adjustments" => receipt.receipt_adjustments.order(:position_index, :id).map do |adjustment|
            {
              "kind" => adjustment.kind,
              "label" => adjustment.label,
              "sign" => adjustment.sign,
              "amount" => adjustment.amount&.to_i,
              "effect" => normalized_adjustment_effect(adjustment),
              "tax_rate" => adjustment.tax_rate&.to_s,
              "review_reasons" => Array(adjustment.review_reasons).map(&:to_s).sort
            }
          end,
          "payment_method" => receipt.payment_method,
          "payments" => receipt.receipt_payments.order(:id).map do |payment|
            {
              "method" => payment.method,
              "amount" => payment.amount&.to_i
            }
          end,
          "status" => receipt.status,
          "review_reasons" => Array(receipt.review_reasons).sort,
          "processing_error_code" => receipt.processing_error_code
        }
      end
    end

    def initialize(case_data, actual)
      @case_data = case_data
      @expected = case_data.fetch("expected")
      @actual = actual
      @diffs = []
    end

    def call
      if non_receipt_case?
        compare_scalar("status", expected["status"], actual["status"])
        compare_array("review_reasons", Array(expected["review_reasons"]).sort, Array(actual["review_reasons"]).sort)
        compare_scalar("processing_error_code", expected["processing_error_code"], actual["processing_error_code"])
        return Result.new(case_id: case_data.fetch("case_id"), status: comparison_status, diffs: diffs)
      end

      compare_scalar("store_name", expected["store_name"], actual["store_name"])
      compare_scalar("subtotal", expected["subtotal"], actual["subtotal"])
      compare_scalar("tax", expected["tax"], actual["tax"])
      compare_scalar("total", expected["total"], actual["total"])
      compare_rate("tax_rate", expected["tax_rate"], actual["tax_rate"])
      compare_tax_details
      compare_items
      compare_adjustments
      compare_scalar("payment_method", expected["payment_method"], actual["payment_method"])
      compare_payments
      compare_scalar("status", expected["status"], actual["status"])
      compare_array("review_reasons", Array(expected["review_reasons"]).sort, Array(actual["review_reasons"]).sort)
      compare_scalar("processing_error_code", expected.fetch("processing_error_code", nil), actual["processing_error_code"])

      Result.new(case_id: case_data.fetch("case_id"), status: comparison_status, diffs: diffs)
    end

    private

    attr_reader :case_data, :expected, :actual, :diffs

    def non_receipt_case?
      case_data["receipt_kind"] == "non_receipt"
    end

    def compare_tax_details
      expected_details = expected["tax_details"].map { |detail| normalize_tax_detail(detail) }.sort_by { |detail| detail["rate"].to_s }
      actual_details = Array(actual["tax_details"]).map { |detail| normalize_tax_detail(detail) }.sort_by { |detail| detail["rate"].to_s }
      compare_array("tax_details", expected_details, actual_details)
    end

    def compare_items
      expected_items = expected["items"].map do |item|
        {
          "name" => normalize_label(item["name"]),
          "line_total" => item["line_total"],
          "tax_rate" => normalize_rate(item["tax_rate"]),
          "discount_amount" => zero_to_nil(item["discount_amount"])
        }
      end
      actual_items = Array(actual["items"]).map do |item|
        {
          "name" => normalize_label(item["name"]),
          "line_total" => item["line_total"],
          "tax_rate" => normalize_rate(item["tax_rate"]),
          "discount_amount" => zero_to_nil(item["discount_amount"])
        }
      end
      compare_array("items", expected_items, actual_items)
    end

    def compare_adjustments
      expected_adjustments = expected["receipt_adjustments"].map do |adjustment|
        {
          "kind" => adjustment["kind"],
          "label" => normalize_label(adjustment["label"]),
          "sign" => adjustment["sign"],
          "amount" => adjustment["amount"],
          "effect" => adjustment["effect"],
          "tax_rate" => normalize_rate(adjustment["tax_rate"]),
          "review_reasons" => Array(adjustment["review_reasons"]).map(&:to_s).sort
        }
      end.sort_by { |adjustment| [ adjustment["kind"].to_s, adjustment["amount"].to_i, adjustment["label"].to_s ] }
      actual_adjustments = Array(actual["receipt_adjustments"]).map do |adjustment|
        {
          "kind" => adjustment["kind"],
          "label" => normalize_label(adjustment["label"]),
          "sign" => adjustment["sign"],
          "amount" => adjustment["amount"],
          "effect" => adjustment["effect"],
          "tax_rate" => normalize_rate(adjustment["tax_rate"]),
          "review_reasons" => Array(adjustment["review_reasons"]).map(&:to_s).sort
        }
      end.sort_by { |adjustment| [ adjustment["kind"].to_s, adjustment["amount"].to_i, adjustment["label"].to_s ] }
      compare_array("receipt_adjustments", expected_adjustments, actual_adjustments)
    end

    def self.normalized_adjustment_effect(adjustment)
      effect = ReceiptAmountService.adjustment_effect(adjustment)
      effect == "payment_adjustment" ? "payment" : "purchase"
    end

    def compare_payments
      expected_payments = expected["payments"].map do |payment|
        {
          "label" => normalize_label(payment["label"]),
          "amount" => payment["amount"]
        }
      end.sort_by { |payment| [ payment["amount"].to_i, payment["label"].to_s ] }
      actual_payments = Array(actual["payments"]).map do |payment|
        {
          "label" => normalize_label(payment["method"]),
          "amount" => payment["amount"]
        }
      end.sort_by { |payment| [ payment["amount"].to_i, payment["label"].to_s ] }
      compare_array("payments", expected_payments, actual_payments)
    end

    def compare_scalar(path, expected_value, actual_value)
      return if expected_value == actual_value

      add_diff(path, expected_value, actual_value)
    end

    def compare_rate(path, expected_value, actual_value)
      expected_rate = normalize_rate(expected_value)
      actual_rate = normalize_rate(actual_value)
      return if expected_rate == actual_rate

      add_diff(path, expected_rate, actual_rate)
    end

    def compare_array(path, expected_value, actual_value)
      return if expected_value == actual_value

      add_diff(path, expected_value, actual_value)
    end

    def normalize_tax_detail(detail)
      {
        "rate" => normalize_rate(detail["rate"]),
        "net" => detail["net"]&.to_i,
        "tax" => detail["tax"]&.to_i,
        "gross" => detail["gross"]&.to_i
      }
    end

    def normalize_rate(value)
      return nil if value.nil?

      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError
      value
    end

    def zero_to_nil(value)
      value.to_i.zero? ? nil : value.to_i
    end

    def normalize_label(value)
      value.to_s.strip.downcase
    end

    def comparison_status
      return "PASS" if diffs.empty?
      return "FAIL" if diffs.any? { |diff| diff[:severity] == "FAIL" }

      "WARN"
    end

    def add_diff(path, expected_value, actual_value)
      diffs << {
        path: path,
        expected: expected_value,
        actual: actual_value,
        severity: fail_path?(path) ? "FAIL" : "WARN"
      }
    end

    def fail_path?(path)
      return true if non_receipt_case? && %w[status processing_error_code].include?(path)

      FAIL_PATHS.include?(path)
    end
  end
end
