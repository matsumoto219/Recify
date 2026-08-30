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
      item_review_states
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
      discount_rate
    ].freeze
    OPTIONAL_ITEM_REVIEW_KEYS = %w[needs_review review_reasons].freeze
    ITEM_REVIEW_REASON_LIMIT = 20
    REFERENCE_PRICING_CANDIDATE_LIMIT = 100
    REFERENCE_PRICING_ITEM_INDEX_MAX = REFERENCE_PRICING_CANDIDATE_LIMIT - 1
    REFERENCE_PRICING_LINE_TOTAL_MAX = 999_999_999
    REFERENCE_PRICING_REJECTION_REASON_LIMIT = 8
    REFERENCE_PRICING_TOKEN_MAX_BYTES = 64
    REFERENCE_PRICING_HASH_KEY_LIMIT = 32
    REFERENCE_PRICING_ROUNDING_MATCHES = %w[floor half_up ceil].freeze
    REFERENCE_PRICING_VALIDATION_STATES = %w[valid missing ambiguous unsupported].freeze
    REFERENCE_PRICING_TAX_INCLUSIONS = %w[gross net unknown].freeze
    REFERENCE_PRICING_PRICE_MAX = BigDecimal("999999999999")
    REFERENCE_PRICING_QUANTITY_MAX = BigDecimal("9999.999")
    REFERENCE_PRICING_PRICE_MAX_SCALE = 6
    REFERENCE_PRICING_QUANTITY_MAX_SCALE = 3
    MALFORMED_CANDIDATE_SUMMARY = {
      "validation_state" => "malformed",
      "rejection_reasons" => []
    }.freeze
    INVALID_COMPARISON_VALUE = "[invalid]"
    COMPARISON_COLLECTION_LIMIT = 100
    COMPARISON_HASH_KEY_LIMIT = 64
    COMPARISON_SNAPSHOT_STRING_MAX_BYTES = 512
    COMPARISON_NESTING_LIMIT = 4
    COMPARISON_NESTED_VALUE_LIMIT = 256
    ACTUAL_ROOT_KEYS = %w[
      store_name subtotal tax total tax_rate tax_details items receipt_adjustments
      payment_method payments status review_reasons processing_error_code
      reference_pricing_candidates
    ].freeze
    ACTUAL_ITEM_KEYS = %w[
      name unit_price quantity quantity_unit_code line_total original_line_total
      tax_rate discount_amount discount_rate pricing_source_kind reference_price_amount
      reference_quantity reference_quantity_unit_code reference_price_tax_inclusion
      tax_inclusion needs_review review_reasons
    ].freeze
    ACTUAL_TAX_DETAIL_KEYS = %w[rate net tax gross basis label].freeze
    ACTUAL_ADJUSTMENT_KEYS = %w[
      kind label sign amount effect tax_rate tax_inclusion review_reasons
    ].freeze
    ACTUAL_PAYMENT_KEYS = %w[method amount].freeze
    ACTUAL_CANDIDATE_KEYS = %w[
      item_index validation_state rejection_reasons reference_price_amount
      reference_quantity reference_unit_code purchased_quantity purchased_unit_code
      reference_price_tax_inclusion projected_line_total printed_line_total
      rounding_matches
    ].freeze
    COMPARISON_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
    COMPARISON_CONTROL_PATTERN = /[\u0000-\u001F\u007F-\u009F]/.freeze
    COMPARISON_SNAPSHOT_CONTROL_PATTERN = /[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]/.freeze

    class << self
      def call(case_data, actual)
        new(case_data, actual).call
      rescue StandardError
        Result.new(
          case_id: safe_case_id(case_data),
          status: "FAIL",
          diffs: [
            {
              path: "comparison_input",
              expected: "valid generated receipt fixture and snapshot",
              actual: "malformed comparison input",
              severity: "FAIL"
            }
          ]
        )
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
              "name" => preferred_item_name(item),
              "unit_price" => item.price&.to_i,
              "quantity" => item.quantity&.to_s,
              "quantity_unit_code" => item.quantity_unit_code,
              "line_total" => item.line_total&.to_i,
              "original_line_total" => item.original_line_total&.to_i,
              "tax_rate" => item.tax_rate&.to_s,
              "discount_amount" => item.discount_amount&.to_i,
              "discount_rate" => exact_decimal_string(
                item.discount_rate,
                maximum: BigDecimal("1"),
                max_scale: 6
              ),
              "pricing_source_kind" => item.pricing_source_kind,
              "reference_price_amount" => exact_decimal_string(
                item.reference_price_amount,
                maximum: REFERENCE_PRICING_PRICE_MAX,
                max_scale: REFERENCE_PRICING_PRICE_MAX_SCALE
              ),
              "reference_quantity" => exact_decimal_string(
                item.reference_quantity,
                maximum: REFERENCE_PRICING_QUANTITY_MAX,
                max_scale: REFERENCE_PRICING_QUANTITY_MAX_SCALE
              ),
              "reference_quantity_unit_code" => item.reference_quantity_unit_code,
              "reference_price_tax_inclusion" => item.reference_price_tax_inclusion,
              "needs_review" => item.needs_review?,
              "review_reasons" => bounded_item_review_reasons(item.review_reasons)
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
        entries = if value.nil?
          []
        elsif value.is_a?(Array)
          return [ MALFORMED_CANDIDATE_SUMMARY.dup ] if value.size > REFERENCE_PRICING_CANDIDATE_LIMIT

          value
        else
          [ nil ]
        end
        entries.map do |entry|
          candidate = strict_indifferent_hash(entry)
          next MALFORMED_CANDIDATE_SUMMARY.dup unless valid_candidate_shape?(candidate)

          reference_price = indifferent_hash(candidate["reference_price"])
          reference_quantity = indifferent_hash(candidate["reference_quantity"])
          purchased_quantity = indifferent_hash(candidate["purchased_quantity"])
          corroboration = indifferent_hash(candidate["corroboration"])

          {
            "item_index" => bounded_candidate_item_index(
              candidate["item_index"],
              maximum: REFERENCE_PRICING_ITEM_INDEX_MAX
            ),
            "validation_state" => bounded_token(candidate["validation_state"]),
            "rejection_reasons" => bounded_tokens(
              candidate["rejection_reasons"],
              limit: REFERENCE_PRICING_REJECTION_REASON_LIMIT
            ),
            "reference_price_amount" => exact_decimal_string(
              candidate["reference_price_amount"] || reference_price["amount"],
              maximum: REFERENCE_PRICING_PRICE_MAX,
              max_scale: REFERENCE_PRICING_PRICE_MAX_SCALE
            ),
            "reference_quantity" => exact_decimal_string(
              reference_quantity["amount"] || candidate["reference_quantity"],
              maximum: REFERENCE_PRICING_QUANTITY_MAX,
              max_scale: REFERENCE_PRICING_QUANTITY_MAX_SCALE
            ),
            "reference_unit_code" => bounded_token(
              candidate["reference_unit_code"] || reference_quantity["unit_code"]
            ),
            "purchased_quantity" => exact_decimal_string(
              purchased_quantity["amount"] || candidate["purchased_quantity"],
              maximum: REFERENCE_PRICING_QUANTITY_MAX,
              max_scale: REFERENCE_PRICING_QUANTITY_MAX_SCALE
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

      def safe_case_id(value)
        return unless value.is_a?(Hash)

        case_id = value["case_id"]
        case_id if Validator.valid_case_id?(case_id)
      end

      def bounded_comparison_string?(value)
        value.is_a?(String) &&
          value.bytesize <= REFERENCE_PRICING_TOKEN_MAX_BYTES &&
          value.valid_encoding? &&
          !value.match?(COMPARISON_CONTROL_PATTERN)
      rescue EncodingError
        false
      end

      def preferred_item_name(item)
        confirmed_name = item.confirmed_name
        return confirmed_name unless confirmed_name.nil? || confirmed_name.to_s.strip.empty?

        item.suggested_name || item.raw_text
      end

      def indifferent_hash(value)
        return {} unless value.respond_to?(:each_pair)

        value.each_pair.each_with_object({}) do |(key, child), result|
          break result if result.size >= REFERENCE_PRICING_HASH_KEY_LIMIT

          normalized_key = bounded_hash_key(key)
          result[normalized_key] = child if normalized_key
        end
      rescue StandardError
        {}
      end

      def strict_indifferent_hash(value)
        return unless value.is_a?(Hash) && value.size <= REFERENCE_PRICING_HASH_KEY_LIMIT

        value.each_pair.each_with_object({}) do |(key, child), result|
          normalized_key = bounded_hash_key(key)
          return unless normalized_key
          return if result.key?(normalized_key)

          result[normalized_key] = child
        end
      rescue StandardError
        nil
      end

      def bounded_hash_key(value)
        token = case value
        when String
          value
        when Symbol
          value.name
        else
          return nil
        end
        return nil if token.empty? || token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.valid_encoding? && token.ascii_only?

        token
      rescue EncodingError
        nil
      end

      def exact_decimal_string(value, maximum:, max_scale:)
        return nil if value.nil?

        token = bounded_decimal_token(value, maximum: maximum, max_scale: max_scale)
        return nil unless token
        return nil if token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.match?(/\A(?:0|[1-9]\d*)(?:\.\d+)?\z/)

        normalized = BigDecimal(token).to_s("F")
        return nil if normalized_decimal_scale(normalized) > max_scale
        return nil if BigDecimal(normalized) > maximum

        normalized = normalized.sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
        normalized == "-0" ? "0" : normalized
      rescue ArgumentError, TypeError, FloatDomainError, EncodingError
        nil
      end

      def bounded_decimal_token(value, maximum:, max_scale:)
        case value
        when String
          return nil if value.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
          return nil unless value.valid_encoding? && value.ascii_only?

          value
        when Integer
          return nil unless value.between?(0, maximum.to_i)

          value.to_s
        when BigDecimal
          return nil unless value.finite? && value >= 0 && value <= maximum
          return nil if value.precision > REFERENCE_PRICING_TOKEN_MAX_BYTES
          return nil if value.scale > max_scale

          value.to_s("F")
        end
      rescue ArgumentError, EncodingError
        nil
      end

      def normalized_decimal_scale(value)
        fraction = value.split(".", 2)[1]
        fraction ? fraction.sub(/0+\z/, "").length : 0
      end

      def bounded_token(value)
        return nil if value.nil?

        token = case value
        when String
          value
        when Symbol
          value.to_s
        else
          return nil
        end
        return nil if token.empty? || token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.valid_encoding?
        return nil unless token.match?(/\A[a-z0-9_:-]+\z/)

        token
      rescue EncodingError
        nil
      end

      def bounded_tokens(value, limit:, allowed: nil)
        return unless valid_token_array?(value, limit: limit, allowed: allowed)

        value.sort
      end

      def bounded_non_negative_integer(value, maximum:)
        if value.is_a?(Integer)
          return value if value.between?(0, maximum)

          return nil
        end
        return nil unless value.is_a?(String)

        token = value
        return nil if token.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless token.valid_encoding? && token.ascii_only?
        return nil unless token.match?(/\A(?:0|[1-9]\d*)\z/)

        integer = Integer(token, 10)
        integer if integer <= maximum
      rescue ArgumentError, TypeError, EncodingError
        nil
      end

      def bounded_candidate_item_index(value, maximum:)
        value if value.is_a?(Integer) && value.between?(0, maximum)
      end

      def valid_candidate_shape?(candidate)
        return false unless candidate.is_a?(Hash)
        return false unless candidate["item_index"].is_a?(Integer)
        return false unless candidate["item_index"].between?(0, REFERENCE_PRICING_ITEM_INDEX_MAX)
        return false unless strict_token?(
          candidate["validation_state"],
          allowed: REFERENCE_PRICING_VALIDATION_STATES
        )
        return false unless valid_token_array?(
          candidate["rejection_reasons"],
          limit: REFERENCE_PRICING_REJECTION_REASON_LIMIT
        )
        return false unless valid_reference_price_component?(candidate["reference_price"])
        return false unless valid_quantity_component?(candidate["reference_quantity"])
        return false unless valid_quantity_component?(candidate["purchased_quantity"])
        return false unless valid_optional_exact_field?(candidate, "reference_price_amount")
        return false unless valid_optional_token_field?(candidate, "reference_unit_code")
        return false unless valid_optional_token_field?(candidate, "purchased_unit_code")
        return false unless valid_optional_tax_inclusion?(candidate)
        return false unless valid_optional_projected_total?(candidate)
        return false unless valid_printed_total_component?(candidate["printed_line_total"])
        return false unless valid_corroboration_component?(candidate["corroboration"])

        !candidate.key?("rounding_matches") || valid_token_array?(
          candidate["rounding_matches"],
          limit: REFERENCE_PRICING_ROUNDING_MATCHES.size,
          allowed: REFERENCE_PRICING_ROUNDING_MATCHES
        )
      end

      def valid_reference_price_component?(value)
        return true if value.nil?

        component = strict_indifferent_hash(value)
        component && valid_optional_exact_field?(component, "amount")
      end

      def valid_quantity_component?(value)
        return true if value.nil?
        return valid_exact_candidate_token?(value) if value.is_a?(String)

        component = strict_indifferent_hash(value)
        component &&
          valid_optional_exact_field?(component, "amount") &&
          valid_optional_token_field?(component, "unit_code") &&
          valid_optional_token_field?(component, "unit_status") &&
          valid_optional_token_field?(component, "origin")
      end

      def valid_printed_total_component?(value)
        return true if value.nil?
        return valid_integer_candidate_token?(value) if value.is_a?(String)

        component = strict_indifferent_hash(value)
        component && valid_optional_integer_string_field?(component, "amount")
      end

      def valid_corroboration_component?(value)
        return true if value.nil?

        corroboration = strict_indifferent_hash(value)
        return false unless corroboration
        return false unless valid_optional_integer_field?(corroboration, "projected_amount")
        return false unless valid_optional_integer_string_field?(corroboration, "printed_line_total")
        if corroboration.key?("rounding_matches") && !valid_token_array?(
          corroboration["rounding_matches"],
          limit: REFERENCE_PRICING_ROUNDING_MATCHES.size,
          allowed: REFERENCE_PRICING_ROUNDING_MATCHES
        )
          return false
        end

        valid_exact_amount_component?(corroboration["exact_amount"])
      end

      def valid_exact_amount_component?(value)
        return true if value.nil?

        exact_amount = strict_indifferent_hash(value)
        return false unless exact_amount
        return false unless exact_amount.key?("numerator") && exact_amount.key?("denominator")

        valid_integer_candidate_token?(exact_amount["numerator"]) &&
          valid_integer_candidate_token?(exact_amount["denominator"], allow_zero: false)
      end

      def valid_optional_exact_field?(container, key)
        !container.key?(key) || container[key].nil? || valid_exact_candidate_token?(container[key])
      end

      def valid_optional_token_field?(container, key)
        !container.key?(key) || container[key].nil? || strict_token?(container[key])
      end

      def valid_optional_tax_inclusion?(candidate)
        !candidate.key?("reference_price_tax_inclusion") ||
          candidate["reference_price_tax_inclusion"].nil? ||
          strict_token?(
            candidate["reference_price_tax_inclusion"],
            allowed: REFERENCE_PRICING_TAX_INCLUSIONS
          )
      end

      def valid_optional_projected_total?(candidate)
        valid_optional_integer_field?(candidate, "projected_line_total")
      end

      def valid_optional_integer_field?(container, key)
        !container.key?(key) || container[key].nil? || container[key].is_a?(Integer)
      end

      def valid_optional_integer_string_field?(container, key)
        !container.key?(key) || container[key].nil? || valid_integer_candidate_token?(container[key])
      end

      def valid_exact_candidate_token?(value)
        value.is_a?(String) &&
          value.bytesize <= REFERENCE_PRICING_TOKEN_MAX_BYTES &&
          value.valid_encoding? &&
          value.ascii_only? &&
          value.match?(COMPARISON_DECIMAL_PATTERN)
      rescue EncodingError
        false
      end

      def valid_integer_candidate_token?(value, allow_zero: true)
        return false unless value.is_a?(String)
        return false if value.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return false unless value.valid_encoding? && value.ascii_only?
        return false unless value.match?(/\A(?:0|[1-9]\d*)\z/)

        allow_zero || value != "0"
      rescue EncodingError
        false
      end

      def strict_token?(value, allowed: nil)
        return false unless value.is_a?(String)

        token = bounded_token(value)
        token == value && (allowed.nil? || allowed.include?(token))
      end

      def valid_token_array?(value, limit:, allowed: nil)
        return false unless value.is_a?(Array) && value.size <= limit
        return false unless value.uniq.size == value.size

        value.all? { |entry| strict_token?(entry, allowed: allowed) }
      end

      def bounded_item_review_reasons(value)
        return unless valid_token_array?(value, limit: ITEM_REVIEW_REASON_LIMIT)

        value.sort
      end
    end

    def initialize(case_data, actual)
      @case_data = case_data.is_a?(Hash) ? case_data : {}
      @expected = @case_data["expected"].is_a?(Hash) ? @case_data["expected"] : {}
      @case_data_shape_valid = valid_case_data_shape?(case_data)
      @actual_shape_valid = valid_actual_shape?(actual)
      @actual = actual.is_a?(Hash) ? actual : {}
      @diffs = []
    end

    def call
      return invalid_comparison_input_result unless case_data_shape_valid && actual_shape_valid

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
      compare_item_review_states
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

    attr_reader :case_data, :expected, :actual, :diffs, :case_data_shape_valid,
      :actual_shape_valid

    def valid_case_data_shape?(value)
      return false unless value.is_a?(Hash) && value.size <= COMPARISON_HASH_KEY_LIMIT
      return false unless self.class.send(:bounded_comparison_string?, value["case_id"])
      return false unless Validator.call(value).valid?

      comparison_expected = value["expected"]
      return false unless comparison_expected.is_a?(Hash)
      return false if comparison_expected.size > COMPARISON_HASH_KEY_LIMIT

      if value["receipt_kind"] == "non_receipt"
        return bounded_string_array?(comparison_expected["review_reasons"])
      end

      %w[items tax_details receipt_adjustments payments].all? do |key|
        bounded_hash_array?(comparison_expected[key])
      end && bounded_string_array?(comparison_expected["review_reasons"]) &&
        valid_expected_item_review_shapes?(comparison_expected["items"]) &&
        valid_expected_candidates_shape?(comparison_expected["reference_pricing_candidates"])
    rescue StandardError
      false
    end

    def bounded_hash_array?(value, maximum: COMPARISON_COLLECTION_LIMIT)
      value.is_a?(Array) && value.size <= maximum && value.all? do |entry|
        entry.is_a?(Hash) && entry.size <= COMPARISON_HASH_KEY_LIMIT
      end
    end

    def valid_actual_shape?(value)
      return false unless value.is_a?(Hash) && value.size <= COMPARISON_HASH_KEY_LIMIT
      return false unless exact_string_keys?(value, ACTUAL_ROOT_KEYS)
      return false unless valid_actual_scalar_fields?(value)
      return false unless valid_actual_collections?(value, required: !non_receipt_case?)
      return false unless bounded_string_array?(value["review_reasons"])

      true
    rescue StandardError
      false
    end

    def valid_actual_collections?(value, required:)
      collections = {
        "tax_details" => ACTUAL_TAX_DETAIL_KEYS,
        "receipt_adjustments" => ACTUAL_ADJUSTMENT_KEYS,
        "payments" => ACTUAL_PAYMENT_KEYS
      }
      valid_items = (!required && !value.key?("items")) || bounded_actual_items?(value["items"])
      valid_items && collections.all? do |key, allowed_keys|
        (!required && !value.key?(key)) ||
          bounded_actual_hash_array?(value[key], allowed_keys: allowed_keys)
      end && bounded_actual_candidates?(value)
    end

    def bounded_actual_items?(value)
      return false unless bounded_actual_hash_array?(value, allowed_keys: ACTUAL_ITEM_KEYS)

      value.all? do |item|
        valid_optional_boolean?(item, "needs_review") &&
          valid_optional_item_review_reasons?(item)
      end
    end

    def valid_actual_scalar_fields?(value)
      %w[
        store_name subtotal tax total tax_rate payment_method status processing_error_code
      ].all? do |key|
        !value.key?(key) || bounded_snapshot_scalar?(value[key])
      end
    end

    def bounded_actual_hash_array?(value, allowed_keys:)
      value.is_a?(Array) && value.size <= COMPARISON_COLLECTION_LIMIT && value.all? do |entry|
        entry.is_a?(Hash) && exact_string_keys?(entry, allowed_keys) && bounded_snapshot_value?(entry)
      end
    end

    def bounded_actual_candidates?(value)
      return true unless value.key?("reference_pricing_candidates")

      candidates = value["reference_pricing_candidates"]
      candidates.is_a?(Array) &&
        candidates.size <= REFERENCE_PRICING_CANDIDATE_LIMIT &&
        candidates.all? do |candidate|
          candidate.is_a?(Hash) &&
            exact_string_keys?(candidate, ACTUAL_CANDIDATE_KEYS) &&
            bounded_snapshot_value?(candidate)
        end
    end

    def exact_string_keys?(value, allowed_keys)
      value.keys.all? do |key|
        key.is_a?(String) && key.bytesize <= REFERENCE_PRICING_TOKEN_MAX_BYTES &&
          key.valid_encoding? && allowed_keys.include?(key)
      end
    rescue EncodingError
      false
    end

    def bounded_snapshot_value?(root)
      stack = [ [ root, 0 ] ]
      visited = 0

      until stack.empty?
        value, depth = stack.pop
        visited += 1
        return false if visited > COMPARISON_NESTED_VALUE_LIMIT
        return false if depth > COMPARISON_NESTING_LIMIT

        case value
        when Hash
          return false if value.size > COMPARISON_HASH_KEY_LIMIT

          value.each_pair do |key, child|
            return false unless bounded_snapshot_key?(key)

            stack << [ child, depth + 1 ]
          end
        when Array
          return false if value.size > COMPARISON_COLLECTION_LIMIT

          value.each { |child| stack << [ child, depth + 1 ] }
        else
          return false unless bounded_snapshot_scalar?(value)
        end
      end

      true
    end

    def bounded_snapshot_key?(value)
      token = case value
      when String
        value
      when Symbol
        value.name
      else
        return false
      end
      token.bytesize <= REFERENCE_PRICING_TOKEN_MAX_BYTES &&
        token.valid_encoding? &&
        token.ascii_only? &&
        !token.match?(COMPARISON_CONTROL_PATTERN)
    rescue EncodingError
      false
    end

    def bounded_snapshot_scalar?(value)
      case value
      when nil, true, false
        true
      when String
        value.bytesize <= COMPARISON_SNAPSHOT_STRING_MAX_BYTES &&
          value.valid_encoding? &&
          !value.match?(COMPARISON_SNAPSHOT_CONTROL_PATTERN)
      when Integer
        value.bit_length <= 128
      when Float
        value.finite?
      when BigDecimal
        value.finite? &&
          value.precision <= REFERENCE_PRICING_TOKEN_MAX_BYTES &&
          value.scale <= REFERENCE_PRICING_TOKEN_MAX_BYTES &&
          value.exponent.abs <= REFERENCE_PRICING_TOKEN_MAX_BYTES
      else
        false
      end
    rescue ArgumentError, EncodingError
      false
    end

    def bounded_string_array?(value, maximum: COMPARISON_COLLECTION_LIMIT)
      value.is_a?(Array) && value.size <= maximum && value.all? do |entry|
        self.class.send(:bounded_comparison_string?, entry)
      end
    end

    def valid_expected_item_review_shapes?(items)
      items.all? do |item|
        valid_optional_boolean?(item, "needs_review") &&
          valid_optional_item_review_reasons?(item)
      end
    end

    def valid_optional_boolean?(container, key)
      !container.key?(key) || container[key] == true || container[key] == false
    end

    def valid_optional_item_review_reasons?(container)
      return true unless container.key?("review_reasons")

      reasons = container["review_reasons"]
      bounded_string_array?(reasons, maximum: ITEM_REVIEW_REASON_LIMIT) &&
        reasons.uniq.size == reasons.size
    end

    def valid_expected_candidates_shape?(value)
      return true if value.nil?
      return false unless bounded_hash_array?(value)

      value.all? do |candidate|
        candidate["item_index"].is_a?(Integer) &&
          candidate["item_index"].between?(0, REFERENCE_PRICING_ITEM_INDEX_MAX) &&
          self.class.send(:bounded_comparison_string?, candidate["validation_state"]) &&
          bounded_string_array?(
            candidate["rejection_reasons"],
            maximum: REFERENCE_PRICING_REJECTION_REASON_LIMIT
          ) &&
          valid_rounding_matches_shape?(candidate["rounding_matches"])
      end
    end

    def valid_rounding_matches_shape?(value)
      value.nil? || (
        bounded_string_array?(value, maximum: REFERENCE_PRICING_ROUNDING_MATCHES.size) &&
          value.all? { |entry| REFERENCE_PRICING_ROUNDING_MATCHES.include?(entry) }
      )
    end

    def invalid_comparison_input_result
      Result.new(
        case_id: self.class.send(:safe_case_id, case_data),
        status: "FAIL",
        diffs: [
          {
            path: "comparison_input",
            expected: "valid generated receipt fixture and snapshot",
            actual: "malformed comparison input",
            severity: "FAIL"
          }
        ]
      )
    end

    def non_receipt_case?
      case_data["receipt_kind"] == "non_receipt"
    end

    def compare_tax_details
      expected_details = expected["tax_details"].map { |detail| normalize_tax_detail(detail) }.sort_by { |detail| detail["rate"].to_s }
      actual_details = Array(actual["tax_details"]).map do |detail|
        normalize_tax_detail(safe_hash_entry(detail))
      end.sort_by { |detail| detail["rate"].to_s }
      compare_array("tax_details", expected_details, actual_details)
    end

    def compare_items
      expected_items = expected["items"].map { |item| normalize_label(item["name"]) }
      actual_items = Array(actual["items"]).map do |item|
        normalize_label(safe_hash_entry(item)["name"])
      end
      compare_array("items", expected_items, actual_items)
    end

    def compare_item_amounts
      expected_items = expected["items"]
      expected_amounts = expected_items.map do |item|
        normalize_item_amounts(item, optional_keys: declared_optional_item_amount_keys(item))
      end
      actual_amounts = Array(actual["items"]).each_with_index.map do |item, index|
        optional_keys = declared_optional_item_amount_keys(expected_items[index] || {})
        normalize_item_amounts(safe_hash_entry(item), optional_keys: optional_keys)
      end
      compare_array("item_amounts", expected_amounts, actual_amounts)
    end

    def compare_item_review_states
      expected_items = expected["items"]
      expected_states = expected_items.map do |item|
        normalize_item_review_state(item, optional_keys: declared_optional_item_review_keys(item))
      end
      actual_states = Array(actual["items"]).each_with_index.map do |item, index|
        optional_keys = declared_optional_item_review_keys(expected_items[index] || {})
        normalize_item_review_state(safe_hash_entry(item), optional_keys: optional_keys)
      end
      compare_array("item_review_states", expected_states, actual_states)
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
        adjustment = safe_hash_entry(adjustment)
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
        payment = safe_hash_entry(payment)
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
      detail = safe_hash_entry(detail)
      {
        "rate" => normalize_rate(detail["rate"]),
        "net" => normalize_snapshot_integer(detail["net"]),
        "tax" => normalize_snapshot_integer(detail["tax"]),
        "gross" => normalize_snapshot_integer(detail["gross"])
      }
    end

    def normalize_item_amounts(item, optional_keys: [])
      normalized = {
        "unit_price" => normalize_snapshot_integer(item["unit_price"]),
        "quantity" => normalize_quantity(item["quantity"]),
        "line_total" => normalize_snapshot_integer(item["line_total"]),
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
      when "reference_price_amount", "reference_quantity", "discount_rate"
        normalize_exact_decimal(value)
      when "original_line_total"
        normalize_snapshot_integer(value)
      else
        value
      end
    end

    def normalize_item_review_state(item, optional_keys: [])
      optional_keys.to_h do |key|
        value = key == "review_reasons" ? Array(item[key]).sort : item[key]
        [ key, value ]
      end
    end

    def declared_optional_item_review_keys(item)
      OPTIONAL_ITEM_REVIEW_KEYS.select { |key| item.key?(key) }
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
      normalize_comparison_decimal(value)
    end

    def normalize_quantity(value)
      normalize_comparison_decimal(value)
    end

    def normalize_exact_decimal(value)
      normalized = normalize_comparison_decimal(value)
      return normalized if normalized.nil? || normalized == INVALID_COMPARISON_VALUE

      normalized = normalized.sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
      normalized == "-0" ? "0" : normalized
    end

    def normalize_integer(value)
      normalize_snapshot_integer(value) || (value.nil? ? nil : INVALID_COMPARISON_VALUE)
    end

    def zero_to_nil(value)
      integer = normalize_snapshot_integer(value)
      return INVALID_COMPARISON_VALUE if integer == INVALID_COMPARISON_VALUE

      integer.to_i.zero? ? nil : integer
    end

    def normalize_label(value)
      return "" if value.nil?
      return INVALID_COMPARISON_VALUE unless value.is_a?(String)

      token = value
      return INVALID_COMPARISON_VALUE if token.bytesize > COMPARISON_SNAPSHOT_STRING_MAX_BYTES
      return INVALID_COMPARISON_VALUE unless token.valid_encoding?
      return INVALID_COMPARISON_VALUE if token.match?(COMPARISON_SNAPSHOT_CONTROL_PATTERN)

      token.strip.downcase
    rescue ArgumentError, EncodingError
      INVALID_COMPARISON_VALUE
    end

    def normalize_comparison_decimal(value)
      return nil if value.nil?

      token = bounded_comparison_numeric_token(value)
      return INVALID_COMPARISON_VALUE unless token
      return INVALID_COMPARISON_VALUE unless token.match?(COMPARISON_DECIMAL_PATTERN)

      BigDecimal(token).to_s("F")
    rescue ArgumentError, TypeError, FloatDomainError, EncodingError
      INVALID_COMPARISON_VALUE
    end

    def bounded_comparison_numeric_token(value)
      case value
      when String
        return nil if value.empty? || value.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil unless value.valid_encoding? && value.ascii_only?

        value
      when Integer
        return nil if value.bit_length > 128

        value.to_s
      when Float
        return nil unless value.finite?

        value.to_s
      when BigDecimal
        return nil unless value.finite?
        return nil if value.precision > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil if value.scale > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return nil if value.exponent.abs > REFERENCE_PRICING_TOKEN_MAX_BYTES

        value.to_s("F")
      end
    rescue EncodingError
      nil
    end

    def normalize_snapshot_integer(value)
      case value
      when nil
        nil
      when Integer
        value.bit_length <= 128 ? value : INVALID_COMPARISON_VALUE
      when String
        return INVALID_COMPARISON_VALUE if value.empty? || value.bytesize > REFERENCE_PRICING_TOKEN_MAX_BYTES
        return INVALID_COMPARISON_VALUE unless value.valid_encoding? && value.ascii_only?
        return INVALID_COMPARISON_VALUE unless value.match?(/\A[+-]?\d+\z/)

        Integer(value, 10)
      else
        INVALID_COMPARISON_VALUE
      end
    rescue ArgumentError, EncodingError
      INVALID_COMPARISON_VALUE
    end

    def safe_hash_entry(value)
      value.is_a?(Hash) ? value : {}
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
      return true if path == "items" && Array(actual_value).include?(INVALID_COMPARISON_VALUE)

      FAIL_PATHS.include?(path)
    end

    def unsafe_status_difference?(expected_status, actual_status)
      expected_status != "completed" || actual_status != "review_needed"
    end
  end
end
