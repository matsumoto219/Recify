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
      item_amounts
      reference_pricing_candidates
      receipt_adjustments
      payment_method
      payments
      processing_error_code
    ].freeze
    OPTIONAL_ITEM_AMOUNT_KEYS = %w[
      quantity_unit_code
      pricing_source_kind
      reference_price_amount
      reference_quantity
      reference_quantity_unit_code
      reference_price_tax_inclusion
      original_line_total
    ].freeze
    REFERENCE_PRICING_CANDIDATE_LIMIT = 100
    REFERENCE_PRICING_ITEM_INDEX_MAX = REFERENCE_PRICING_CANDIDATE_LIMIT - 1
    REFERENCE_PRICING_LINE_TOTAL_MAX = 999_999_999
    REFERENCE_PRICING_REJECTION_REASON_LIMIT = 8
    REFERENCE_PRICING_TOKEN_MAX_BYTES = 64
    REFERENCE_PRICING_ROUNDING_MATCHES = %w[floor half_up ceil].freeze

    class << self
      def call(case_data, actual)
        new(case_data, actual).call
      end

      def snapshot_from_receipt(receipt, reference_pricing_candidates: nil)
        snapshot = {
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
              "unit_price" => item.price&.to_i,
              "quantity" => item.quantity&.to_s,
              "quantity_unit_code" => item.quantity_unit_code,
              "line_total" => item.line_total&.to_i,
              "original_line_total" => item.original_line_total&.to_i,
              "tax_rate" => item.tax_rate&.to_s,
              "discount_amount" => item.discount_amount&.to_i,
              "pricing_source_kind" => item.pricing_source_kind,
              "reference_price_amount" => exact_decimal_string(item.reference_price_amount),
              "reference_quantity" => exact_decimal_string(item.reference_quantity),
              "reference_quantity_unit_code" => item.reference_quantity_unit_code,
              "reference_price_tax_inclusion" => item.reference_price_tax_inclusion
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
        unless reference_pricing_candidates.nil?
          snapshot["reference_pricing_candidates"] = reference_pricing_candidates_summary(
            reference_pricing_candidates
          )
        end
        snapshot
      end

      def reference_pricing_candidates_summary(value)
        Array(value).first(REFERENCE_PRICING_CANDIDATE_LIMIT).filter_map do |entry|
          candidate = indifferent_hash(entry)
          next if candidate.empty?

          reference_price = indifferent_hash(candidate["reference_price"])
          reference_quantity = indifferent_hash(candidate["reference_quantity"])
          purchased_quantity = indifferent_hash(candidate["purchased_quantity"])
          corroboration = indifferent_hash(candidate["corroboration"])

          {
            "item_index" => bounded_non_negative_integer(
              candidate["item_index"],
              maximum: REFERENCE_PRICING_ITEM_INDEX_MAX
            ),
            "validation_state" => bounded_token(candidate["validation_state"]),
            "rejection_reasons" => bounded_tokens(
              candidate["rejection_reasons"],
              limit: REFERENCE_PRICING_REJECTION_REASON_LIMIT
            ),
            "reference_price_amount" => exact_decimal_string(
              candidate["reference_price_amount"] || reference_price["amount"]
            ),
            "reference_quantity" => exact_decimal_string(
              reference_quantity["amount"] || candidate["reference_quantity"]
            ),
            "reference_unit_code" => bounded_token(
              candidate["reference_unit_code"] || reference_quantity["unit_code"]
            ),
            "purchased_quantity" => exact_decimal_string(
              purchased_quantity["amount"] || candidate["purchased_quantity"]
            ),
            "purchased_unit_code" => bounded_token(
              candidate["purchased_unit_code"] || purchased_quantity["unit_code"]
            ),
            "reference_price_tax_inclusion" => bounded_token(
              candidate["reference_price_tax_inclusion"]
            ),
            "projected_line_total" => bounded_non_negative_integer(
              candidate["projected_line_total"] || corroboration["projected_amount"],
              maximum: REFERENCE_PRICING_LINE_TOTAL_MAX
            ),
            "printed_line_total" => bounded_non_negative_integer(
              indifferent_hash(candidate["printed_line_total"])["amount"] || candidate["printed_line_total"],
              maximum: REFERENCE_PRICING_LINE_TOTAL_MAX
            ),
            "rounding_matches" => bounded_tokens(
              candidate["rounding_matches"] || corroboration["rounding_matches"],
              limit: REFERENCE_PRICING_ROUNDING_MATCHES.size,
              allowed: REFERENCE_PRICING_ROUNDING_MATCHES
            )
          }.compact
        end
      end

      private

      def indifferent_hash(value)
        return {} unless value.respond_to?(:each_pair)

        value.each_pair.with_object({}) { |(key, child), result| result[key.to_s] = child }
      rescue StandardError
        {}
      end

      def exact_decimal_string(value)
        return nil if value.nil?

        token = value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
        return nil if token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.match?(/\A[+-]?\d+(?:\.\d+)?\z/)

        normalized = BigDecimal(token).to_s("F")
        normalized = normalized.sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
        normalized == "-0" ? "0" : normalized
      rescue ArgumentError, TypeError, FloatDomainError
        nil
      end

      def bounded_token(value)
        return nil if value.nil?

        token = value.to_s
        return nil unless token.valid_encoding?
        return nil if token.empty? || token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.match?(/\A[a-z0-9_:-]+\z/)

        token
      rescue EncodingError
        nil
      end

      def bounded_tokens(value, limit:, allowed: nil)
        Array(value).first(limit).filter_map do |entry|
          token = bounded_token(entry)
          token if token && (allowed.nil? || allowed.include?(token))
        end.uniq.sort
      end

      def bounded_non_negative_integer(value, maximum:)
        return value if value.is_a?(Integer) && value.between?(0, maximum)

        token = value.to_s
        return nil if token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.match?(/\A(?:0|[1-9]\d*)\z/)

        integer = Integer(token, 10)
        integer if integer <= maximum
      rescue ArgumentError, TypeError
        nil
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
      compare_item_amounts
      compare_reference_pricing_candidates if expected.key?("reference_pricing_candidates")
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
      expected_items = expected["items"].map { |item| normalize_label(item["name"]) }
      actual_items = Array(actual["items"]).map { |item| normalize_label(item["name"]) }
      compare_array("items", expected_items, actual_items)
    end

    def compare_item_amounts
      expected_items = expected["items"]
      expected_amounts = expected_items.map do |item|
        normalize_item_amounts(item, optional_keys: declared_optional_item_amount_keys(item))
      end
      actual_amounts = Array(actual["items"]).each_with_index.map do |item, index|
        optional_keys = declared_optional_item_amount_keys(expected_items[index] || {})
        normalize_item_amounts(item, optional_keys: optional_keys)
      end
      compare_array("item_amounts", expected_amounts, actual_amounts)
    end

    def compare_reference_pricing_candidates
      expected_candidates = Array(expected["reference_pricing_candidates"])
        .map { |candidate| normalize_expected_reference_pricing_candidate(candidate) }
      asserted_candidates = expected_candidates.reject { |candidate| candidate["validation_state"] == "none" }
      actual_candidates = self.class.reference_pricing_candidates_summary(
        actual["reference_pricing_candidates"]
      )
      expected_by_index = asserted_candidates.to_h { |candidate| [ candidate["item_index"], candidate ] }
      projected_actual = actual_candidates.map do |candidate|
        expectation = expected_by_index[candidate["item_index"]]
        next candidate unless expectation

        expectation.keys.to_h { |key| [ key, candidate[key] ] }
      end

      compare_array(
        "reference_pricing_candidates",
        asserted_candidates.sort_by { |candidate| candidate["item_index"].to_i },
        projected_actual.sort_by { |candidate| candidate["item_index"].to_i }
      )
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

    def normalize_item_amounts(item, optional_keys: [])
      normalized = {
        "unit_price" => item["unit_price"]&.to_i,
        "quantity" => normalize_quantity(item["quantity"]),
        "line_total" => item["line_total"]&.to_i,
        "tax_rate" => normalize_rate(item["tax_rate"]),
        "discount_amount" => zero_to_nil(item["discount_amount"])
      }
      optional_keys.each do |key|
        normalized[key] = normalize_optional_item_amount(key, item[key])
      end
      normalized
    end

    def declared_optional_item_amount_keys(item)
      OPTIONAL_ITEM_AMOUNT_KEYS.select { |key| item.key?(key) }
    end

    def normalize_optional_item_amount(key, value)
      case key
      when "reference_price_amount", "reference_quantity"
        normalize_exact_decimal(value)
      when "original_line_total"
        value&.to_i
      else
        value
      end
    end

    def normalize_expected_reference_pricing_candidate(candidate)
      normalized = {
        "item_index" => normalize_integer(candidate["item_index"]),
        "validation_state" => candidate["validation_state"].to_s,
        "rejection_reasons" => Array(candidate["rejection_reasons"]).map(&:to_s).uniq.sort
      }
      %w[reference_price_amount reference_quantity purchased_quantity].each do |key|
        normalized[key] = normalize_exact_decimal(candidate[key]) if candidate.key?(key)
      end
      %w[reference_unit_code purchased_unit_code reference_price_tax_inclusion].each do |key|
        normalized[key] = candidate[key] if candidate.key?(key)
      end
      %w[projected_line_total printed_line_total].each do |key|
        normalized[key] = normalize_integer(candidate[key]) if candidate.key?(key)
      end
      if candidate.key?("rounding_matches")
        normalized["rounding_matches"] = Array(candidate["rounding_matches"]).map(&:to_s).uniq.sort
      end
      normalized
    end

    def normalize_rate(value)
      return nil if value.nil?

      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError
      value
    end

    def normalize_quantity(value)
      return nil if value.nil?

      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError
      value
    end

    def normalize_exact_decimal(value)
      return nil if value.nil?

      normalized = BigDecimal(value.to_s).to_s("F")
      normalized = normalized.sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
      normalized == "-0" ? "0" : normalized
    rescue ArgumentError
      value
    end

    def normalize_integer(value)
      Integer(value)
    rescue ArgumentError, TypeError
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
        severity: fail_path?(path, expected_value, actual_value) ? "FAIL" : "WARN"
      }
    end

    def fail_path?(path, expected_value, actual_value)
      return true if non_receipt_case? && %w[status processing_error_code].include?(path)
      return unsafe_status_difference?(expected_value, actual_value) if path == "status"

      FAIL_PATHS.include?(path)
    end

    def unsafe_status_difference?(expected_status, actual_status)
      expected_status != "completed" || actual_status != "review_needed"
    end
  end
end
