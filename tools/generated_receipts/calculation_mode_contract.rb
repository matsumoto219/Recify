# frozen_string_literal: true

require "bigdecimal"

module GeneratedReceipts
  class CalculationModeContract
    Decision = Data.define(:pricing_source_kind, :state)

    COUNT_TAX_SEMANTICS = %w[reproducible_as_recorded unknown].freeze
    PURCHASED_QUANTITY_ORIGINS = %w[explicit fallback missing].freeze
    COUNTABLE_UNIT_CODES = %w[each item piece bag sheet unit box set].freeze
    CANONICAL_UNIT_CODES = (COUNTABLE_UNIT_CODES + MeasurementContract::UNIT_SCALES.keys).freeze
    FORMULA_CONFLICTS = %w[
      adjacent_item
      dimension_mismatch
      multiple_reference_expression
      package_content
      unsupported_unit
    ].freeze
    REVIEWABLE_FORMULA_CONFLICTS = %w[multiple_reference_expression].freeze
    ITEM_PRICING_MODE_REVIEW_REASON = "item_pricing_mode_uncertain"
    MAX_REVIEW_REASONS = 20
    MAX_REVIEW_REASON_BYTES = 64
    MAX_ITEMS = 100
    MAX_ERRORS = 100
    EXACT_INTEGER_PATTERN = /\A(?:0|[1-9]\d*)\z/.freeze

    class << self
      def validate(case_data)
        return [] unless case_data.is_a?(Hash) && case_data["category"] == "calculation_mode"

        new(case_data).validate
      end
    end

    def initialize(case_data)
      @source = case_data["source"].is_a?(Hash) ? case_data["source"] : {}
      @expected = case_data["expected"].is_a?(Hash) ? case_data["expected"] : {}
      @errors = []
    end

    def validate
      validate_root_contract
      return errors if errors.any?

      source_items.each_with_index do |source_item, source_index|
        validate_item(source_item, expected_items.fetch(source_item.fetch("item_index")), source_index)
      end
      errors
    rescue ArgumentError, KeyError, TypeError
      add_error("calculation_mode", "must contain a complete bounded fixture contract")
      errors
    end

    private

    attr_reader :errors, :expected, :source

    def source_items
      @source_items ||= Array(source["items"])
    end

    def expected_items
      @expected_items ||= Array(expected["items"])
    end

    def validate_root_contract
      unless source["context"] == "analysis"
        add_error("source.context", "must be analysis for calculation-mode fixtures")
      end
      unless COUNT_TAX_SEMANTICS.include?(source["count_tax_semantics"])
        add_error("source.count_tax_semantics", "must declare the bounded receipt-level count tax semantics")
      end
      unless valid_item_collection?(source_items) && expected_items.size.between?(1, MAX_ITEMS)
        add_error("source.items", "item_index values must uniquely and exactly cover expected.items")
        return
      end

      indexes = source_items.map { |item| item["item_index"] }
      expected_indexes = (0...expected_items.size).to_a
      return if indexes.sort == expected_indexes && indexes.uniq.size == indexes.size

      add_error("source.items", "item_index values must uniquely and exactly cover expected.items")
    end

    def valid_item_collection?(items)
      items.is_a?(Array) && items.size.between?(1, MAX_ITEMS) && items.all? do |item|
        item.is_a?(Hash) && item["item_index"].is_a?(Integer)
      end
    end

    def validate_item(source_item, expected_item, source_index)
      unless expected_item.is_a?(Hash)
        add_error("expected.items[#{source_item['item_index']}]", "must be a bounded item object")
        return
      end

      item_index = source_item.fetch("item_index")
      validate_formula_conflicts(source_item, source_index)
      validate_review_state(expected_item, item_index)
      validate_decision(source_item, expected_item, item_index)
      case expected_item["pricing_source_kind"]
      when "count_unit_price"
        validate_count_authority(source_item, expected_item, source_index, item_index)
      when "reference_quantity_price"
        validate_reference_authority(source_item, expected_item, source_index, item_index)
      when "explicit_line_total"
        validate_explicit_authority(source_item, expected_item, source_index, item_index)
      when nil
        validate_unclassified(expected_item, item_index)
      else
        add_error("expected.items[#{item_index}].pricing_source_kind", "must be an approved pricing source kind or null")
      end
    end

    def validate_review_state(item, item_index)
      needs_review = item["needs_review"]
      reasons = item["review_reasons"]
      unless needs_review == true || needs_review == false
        add_error("expected.items[#{item_index}].needs_review", "must be a boolean")
      end
      unless bounded_review_reasons?(reasons)
        add_error("expected.items[#{item_index}].review_reasons", "must be a bounded unique reason array")
        return
      end
      if reasons.any? && needs_review != true
        add_error("expected.items[#{item_index}].needs_review", "must be true when review_reasons are present")
      elsif reasons.empty? && needs_review != false
        add_error("expected.items[#{item_index}].needs_review", "must be false when review_reasons are empty")
      end
    end

    def validate_decision(source_item, item, item_index)
      decision = decision_for(source_item, item)
      unless item["pricing_source_kind"] == decision.pricing_source_kind
        add_error(
          "expected.items[#{item_index}].pricing_source_kind",
          "must select #{decision.pricing_source_kind || 'null'} from the declared exact evidence"
        )
      end

      reasons = Array(item["review_reasons"])
      has_mode_review = reasons.include?(ITEM_PRICING_MODE_REVIEW_REASON)
      if %i[reviewable unresolved].include?(decision.state) && !has_mode_review
        add_error(
          "expected.items[#{item_index}].review_reasons",
          "must include #{ITEM_PRICING_MODE_REVIEW_REASON} for the declared evidence"
        )
      elsif decision.state == :confirmed && has_mode_review
        add_error(
          "expected.items[#{item_index}].review_reasons",
          "must not include #{ITEM_PRICING_MODE_REVIEW_REASON} for confirmed exact evidence"
        )
      end
    end

    def decision_for(source_item, item)
      if formula_conflicted?(source_item)
        return conflict_decision(source_item)
      end
      if unsupported_reference_tax_semantics?(source_item, item)
        return unsupported_reference_tax_decision(source_item)
      end

      reference_projection = reference_projection_for(source_item, item)
      if reference_projection
        return formula_decision(
          "reference_quantity_price",
          reference_projection.projected_gross_line_total,
          source_item
        )
      end

      count_total = count_total_for(source_item)
      if count_total
        return count_decision(count_total, source_item)
      end

      if bounded_printed_total(source_item)
        Decision.new(pricing_source_kind: "explicit_line_total", state: :confirmed)
      else
        Decision.new(pricing_source_kind: nil, state: :unresolved)
      end
    end

    def conflict_decision(source_item)
      printed_total = bounded_printed_total(source_item)
      return Decision.new(pricing_source_kind: nil, state: :unresolved) unless printed_total

      state = if (formula_conflicts(source_item) & REVIEWABLE_FORMULA_CONFLICTS).any?
        :reviewable
      else
        :confirmed
      end
      Decision.new(pricing_source_kind: "explicit_line_total", state:)
    end

    def unsupported_reference_tax_decision(source_item)
      if bounded_printed_total(source_item)
        Decision.new(pricing_source_kind: "explicit_line_total", state: :reviewable)
      else
        Decision.new(pricing_source_kind: nil, state: :unresolved)
      end
    end

    def formula_decision(pricing_source_kind, projected_total, source_item)
      printed_total = bounded_printed_total(source_item)
      if printed_total && printed_total != projected_total
        Decision.new(pricing_source_kind: "explicit_line_total", state: :reviewable)
      else
        Decision.new(pricing_source_kind:, state: :confirmed)
      end
    end

    def count_decision(projected_total, source_item)
      printed_total = bounded_printed_total(source_item)
      if source["count_tax_semantics"] == "unknown"
        if printed_total == projected_total
          Decision.new(pricing_source_kind: "count_unit_price", state: :reviewable)
        elsif printed_total
          Decision.new(pricing_source_kind: "explicit_line_total", state: :reviewable)
        else
          Decision.new(pricing_source_kind: nil, state: :unresolved)
        end
      else
        formula_decision("count_unit_price", projected_total, source_item)
      end
    end

    def count_total_for(source_item)
      return unless source_item["purchased_quantity_origin"] == "explicit"
      return unless COUNTABLE_UNIT_CODES.include?(source_item["purchased_unit"])

      price = exact_integer(source_item["count_unit_price_amount"])
      quantity = exact_integer(source_item["purchased_quantity"])
      return unless price&.between?(0, MeasurementContract::MAX_LINE_TOTAL)
      return unless quantity&.between?(1, MeasurementContract::MAX_QUANTITY.to_i)

      projected = price * quantity
      discount = bounded_discount(source_item["discount_amount"], projected)
      discount ? projected - discount : nil
    end

    def reference_projection_for(source_item, item)
      return unless source_item["purchased_quantity_origin"] == "explicit"
      return unless source_item["reference_price_tax_inclusion"] == "gross"

      projection = MeasurementContract.project(
        source_item: source_item,
        tax_rate: item["tax_rate"],
        tax_rounding: expected.dig("rounding", "tax"),
        discount_rounding: expected.dig("rounding", "discount")
      )
      projection if projection&.projected_gross_line_total
    end

    def unsupported_reference_tax_semantics?(source_item, item)
      inclusion = source_item["reference_price_tax_inclusion"]
      return false unless %w[net unknown].include?(inclusion)

      projected_source = if inclusion == "unknown"
        source_item.merge("reference_price_tax_inclusion" => "gross")
      else
        source_item
      end
      projection = MeasurementContract.project(
        source_item: projected_source,
        tax_rate: item["tax_rate"],
        tax_rounding: expected.dig("rounding", "tax"),
        discount_rounding: expected.dig("rounding", "discount")
      )
      !projection&.projected_gross_line_total.nil?
    end

    def validate_formula_conflicts(source_item, source_index)
      return unless source_item.key?("formula_conflicts")
      return if formula_conflicts(source_item)

      add_error(
        "source.items[#{source_index}].formula_conflicts",
        "must be a bounded unique formula conflict array"
      )
    end

    def formula_conflicted?(source_item)
      formula_conflicts(source_item)&.any?
    end

    def formula_conflicts(source_item)
      value = source_item["formula_conflicts"]
      return [] if value.nil?
      return unless value.is_a?(Array) && value.size <= FORMULA_CONFLICTS.size
      return unless value.uniq.size == value.size && (value - FORMULA_CONFLICTS).empty?

      value
    end

    def bounded_printed_total(source_item)
      value = source_item["printed_line_total"]
      value if value.is_a?(Integer) && value.between?(0, MeasurementContract::MAX_LINE_TOTAL)
    end

    def bounded_review_reasons?(reasons)
      reasons.is_a?(Array) && reasons.size <= MAX_REVIEW_REASONS && reasons.uniq.size == reasons.size &&
        reasons.all? do |reason|
          reason.is_a?(String) && reason.bytesize.between?(1, MAX_REVIEW_REASON_BYTES) &&
            reason.valid_encoding? && !reason.match?(/[\u0000-\u001F\u007F-\u009F]/)
        end
    rescue EncodingError
      false
    end

    def validate_count_authority(source_item, item, source_index, item_index)
      price = exact_integer(source_item["count_unit_price_amount"])
      unless price&.between?(0, MeasurementContract::MAX_LINE_TOTAL)
        add_error("source.items[#{source_index}].count_unit_price_amount", "must be a bounded exact integer")
        return
      end
      unless source_item["purchased_quantity_origin"] == "explicit"
        add_error(
          "source.items[#{source_index}].purchased_quantity_origin",
          "must be explicit for count-unit pricing authority"
        )
      end
      quantity = exact_integer(source_item["purchased_quantity"])
      unless quantity&.between?(1, MeasurementContract::MAX_QUANTITY.to_i) &&
          COUNTABLE_UNIT_CODES.include?(source_item["purchased_unit"])
        add_error(
          "source.items[#{source_index}].purchased_quantity",
          "must be an explicit positive countable integer within bounds"
        )
        return
      end

      projected = price * quantity
      discount = bounded_discount(source_item["discount_amount"], projected)
      if discount.nil?
        add_error("source.items[#{source_index}].discount_amount", "must be bounded by the projected count amount")
        return
      end
      line_total = projected - discount
      validate_matching_printed_total(source_item, line_total, source_index)
      validate_exact_value(item, "unit_price", price, item_index)
      validate_exact_decimal_value(item, "quantity", source_item["purchased_quantity"], item_index)
      validate_exact_value(item, "quantity_unit_code", source_item["purchased_unit"], item_index)
      validate_exact_value(item, "discount_amount", discount, item_index)
      validate_exact_value(
        item,
        "original_line_total",
        projected,
        item_index,
        message: "must equal the independently projected count amount #{projected}"
      )
      validate_exact_value(
        item,
        "line_total",
        line_total,
        item_index,
        message: "must equal the independently projected discounted count amount #{line_total}"
      )
      validate_absent_reference_fields(item, item_index)
    end

    def validate_reference_authority(source_item, item, source_index, item_index)
      unless source_item["purchased_quantity_origin"] == "explicit"
        add_error(
          "source.items[#{source_index}].purchased_quantity_origin",
          "must be explicit for reference_quantity_price authority"
        )
      end
      unless source_item["reference_price_tax_inclusion"] == "gross"
        add_error(
          "source.items[#{source_index}].reference_price_tax_inclusion",
          "must be gross for reference_quantity_price authority"
        )
        return
      end

      projection = MeasurementContract.project(
        source_item: source_item,
        tax_rate: item["tax_rate"],
        tax_rounding: expected.dig("rounding", "tax"),
        discount_rounding: expected.dig("rounding", "discount")
      )
      unless projection && projection.projected_gross_line_total
        add_error("source.items[#{source_index}]", "must be an independently projectable gross reference source")
        return
      end

      validate_matching_printed_total(source_item, projection.projected_gross_line_total, source_index)
      validate_exact_value(item, "unit_price", nil, item_index)
      validate_exact_decimal_value(item, "quantity", source_item["purchased_quantity"], item_index)
      validate_exact_value(item, "quantity_unit_code", source_item["purchased_unit"], item_index)
      validate_exact_decimal_value(item, "reference_price_amount", source_item["reference_price_amount"], item_index)
      validate_exact_decimal_value(item, "reference_quantity", source_item["reference_quantity"], item_index)
      validate_exact_value(item, "reference_quantity_unit_code", source_item["reference_unit"], item_index)
      validate_exact_value(item, "reference_price_tax_inclusion", "gross", item_index)
      validate_exact_value(item, "discount_amount", projection.discount_amount, item_index)
      validate_exact_value(
        item,
        "original_line_total",
        projection.projected_reference_line_total,
        item_index,
        message: "must equal the independently projected reference amount #{projection.projected_reference_line_total}"
      )
      validate_exact_value(
        item,
        "line_total",
        projection.discounted_source_line_total,
        item_index,
        message: "must equal the independently projected discounted reference amount #{projection.discounted_source_line_total}"
      )
    end

    def validate_explicit_authority(source_item, item, source_index, item_index)
      total = source_item["printed_line_total"]
      unless total.is_a?(Integer) && total.between?(0, MeasurementContract::MAX_LINE_TOTAL)
        add_error("source.items[#{source_index}].printed_line_total", "is required for explicit_line_total authority")
        return
      end

      validate_exact_value(item, "unit_price", nil, item_index)
      validate_exact_decimal_value(item, "quantity", source_item["purchased_quantity"], item_index)
      validate_exact_value(item, "quantity_unit_code", source_item["purchased_unit"], item_index)
      validate_exact_value(item, "discount_amount", 0, item_index)
      validate_exact_value(item, "original_line_total", total, item_index)
      validate_exact_value(item, "line_total", total, item_index)
      validate_absent_reference_fields(item, item_index)
    end

    def validate_unclassified(item, item_index)
      validate_exact_value(item, "unit_price", nil, item_index)
      validate_exact_value(item, "original_line_total", nil, item_index)
      validate_exact_value(item, "line_total", nil, item_index)
      validate_absent_reference_fields(item, item_index)
    end

    def validate_absent_reference_fields(item, item_index)
      %w[
        reference_price_amount
        reference_quantity
        reference_quantity_unit_code
        reference_price_tax_inclusion
      ].each do |field|
        next if item[field].nil?

        add_error("expected.items[#{item_index}].#{field}", "must be null for #{item['pricing_source_kind'] || 'unclassified'} authority")
      end
    end

    def validate_matching_printed_total(source_item, projected, source_index)
      return unless source_item.key?("printed_line_total")
      return if source_item["printed_line_total"] == projected

      add_error(
        "source.items[#{source_index}].printed_line_total",
        "must equal the independently projected selected amount #{projected}"
      )
    end

    def validate_exact_value(item, field, expected_value, item_index, message: nil)
      return if item[field] == expected_value

      add_error(
        "expected.items[#{item_index}].#{field}",
        message || "must equal the independently declared source #{expected_value.inspect}"
      )
    end

    def validate_exact_decimal_value(item, field, expected_value, item_index)
      return if exact_decimal(item[field]) == exact_decimal(expected_value)

      add_error(
        "expected.items[#{item_index}].#{field}",
        "must equal the independently declared source #{expected_value.inspect}"
      )
    end

    def exact_integer(value)
      return unless value.is_a?(String) && value.bytesize <= MeasurementContract::EXACT_TOKEN_MAX_BYTES
      return unless value.match?(EXACT_INTEGER_PATTERN)

      Integer(value, 10)
    rescue ArgumentError
      nil
    end

    def exact_decimal(value)
      return if value.nil?

      token = value.is_a?(String) ? value : value.to_s
      return unless token.bytesize <= MeasurementContract::EXACT_TOKEN_MAX_BYTES
      return unless token.match?(MeasurementContract::DECIMAL_PATTERN)

      BigDecimal(token).to_s("F")
    rescue ArgumentError, EncodingError, TypeError
      nil
    end

    def bounded_discount(value, projected)
      return 0 if value.nil?
      return unless value.is_a?(Integer) && value.between?(0, projected)

      value
    end

    def add_error(path, message)
      return if errors.size >= MAX_ERRORS

      errors << "#{path}: #{message}"
    end
  end
end
