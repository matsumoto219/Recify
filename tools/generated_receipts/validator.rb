# frozen_string_literal: true

require "bigdecimal"
require "json"

module GeneratedReceipts
  class Validator
    Result = Struct.new(:case_id, :errors, keyword_init: true) do
      def valid?
        errors.empty?
      end
    end

    TOP_LEVEL_KEYS = %w[
      case_id
      category
      intent
      receipt_kind
      expected
      render
      degradation
      assertions
    ].freeze
    TOP_LEVEL_REQUIRED_KEYS = TOP_LEVEL_KEYS.freeze
    EXPECTED_KEYS = %w[
      store_name
      store_address
      purchased_at
      currency
      amount_basis
      tax_rate
      rounding
      items
      receipt_adjustments
      tax_details
      subtotal
      tax
      total
      payments
      payment_sum
      payment_method
      settlement
      status
      review_reasons
    ].freeze
    EXPECTED_REQUIRED_KEYS = (
      EXPECTED_KEYS - %w[settlement]
    ).freeze
    ROUNDING_KEYS = %w[tax discount scope].freeze
    ITEM_KEYS = %w[
      name
      unit_price
      quantity
      line_total
      tax_rate
      discount_amount
      tax_inclusion
    ].freeze
    ITEM_REQUIRED_KEYS = %w[
      name
      unit_price
      quantity
      line_total
      tax_rate
      discount_amount
    ].freeze
    ADJUSTMENT_KEYS = %w[
      kind
      label
      sign
      amount
      effect
      tax_rate
      tax_inclusion
      review_reasons
    ].freeze
    ADJUSTMENT_REQUIRED_KEYS = %w[
      kind
      label
      sign
      amount
      effect
    ].freeze
    TAX_DETAIL_KEYS = %w[rate net tax gross basis label].freeze
    TAX_DETAIL_REQUIRED_KEYS = %w[rate net tax gross basis].freeze
    PAYMENT_KEYS = %w[method label amount].freeze
    PAYMENT_REQUIRED_KEYS = PAYMENT_KEYS.freeze
    SETTLEMENT_KEYS = %w[tendered change payment_label].freeze
    RENDER_KEYS = %w[locale paper_width font include_tax_detail_lines noise_lines].freeze
    DEGRADATION_KEYS = %w[enabled profile].freeze
    ASSERTION_KEYS = %w[
      critical_exact
      allow_review_reasons
      allow_item_name_minor_diff
      simulated_ai_item_tax_rate
      expected_item_tax_rate_after_save
    ].freeze
    CATEGORIES = %w[normal payment discount_adjustment tax_rounding ocr_anomaly].freeze
    RECEIPT_KINDS = %w[receipt non_receipt].freeze
    AMOUNT_BASES = %w[tax_included tax_excluded].freeze
    TAX_INCLUSIONS = %w[gross net].freeze
    ADJUSTMENT_EFFECTS = %w[purchase payment].freeze
    ADJUSTMENT_SIGNS = %w[surcharge discount].freeze
    ROUNDING_MODES = %w[floor round ceil].freeze

    class << self
      def call(value)
        new(value).call
      end

      def load_file(path)
        JSON.parse(File.read(path))
      end
    end

    def initialize(value)
      @case_data = value
      @errors = []
    end

    def call
      validate_schema
      validate_amounts if errors.empty? && receipt_case?

      Result.new(case_id: case_data["case_id"], errors: errors)
    end

    private

    attr_reader :case_data, :errors

    def validate_schema
      validate_hash("case", case_data, required: TOP_LEVEL_REQUIRED_KEYS, allowed: TOP_LEVEL_KEYS)
      return if errors.any?

      validate_inclusion("category", case_data["category"], CATEGORIES)
      validate_inclusion("receipt_kind", case_data["receipt_kind"], RECEIPT_KINDS)
      validate_hash("expected", expected, required: EXPECTED_REQUIRED_KEYS, allowed: EXPECTED_KEYS)
      validate_hash("expected.rounding", expected["rounding"], required: ROUNDING_KEYS, allowed: ROUNDING_KEYS)
      validate_optional_hash("expected.settlement", expected["settlement"], allowed: SETTLEMENT_KEYS)
      validate_hash("render", case_data["render"], required: [], allowed: RENDER_KEYS)
      validate_hash("degradation", case_data["degradation"], required: DEGRADATION_KEYS, allowed: DEGRADATION_KEYS)
      validate_hash("assertions", case_data["assertions"], required: [], allowed: ASSERTION_KEYS)
      validate_inclusion("expected.amount_basis", expected["amount_basis"], AMOUNT_BASES)
      validate_inclusion("expected.rounding.tax", expected.dig("rounding", "tax"), ROUNDING_MODES)
      validate_array("expected.items", expected["items"]) do |item, index|
        validate_hash("expected.items[#{index}]", item, required: ITEM_REQUIRED_KEYS, allowed: ITEM_KEYS)
        validate_optional_inclusion("expected.items[#{index}].tax_inclusion", item["tax_inclusion"], TAX_INCLUSIONS)
      end
      validate_array("expected.receipt_adjustments", expected["receipt_adjustments"]) do |adjustment, index|
        validate_hash("expected.receipt_adjustments[#{index}]", adjustment, required: ADJUSTMENT_REQUIRED_KEYS, allowed: ADJUSTMENT_KEYS)
        validate_inclusion("expected.receipt_adjustments[#{index}].effect", adjustment["effect"], ADJUSTMENT_EFFECTS)
        validate_inclusion("expected.receipt_adjustments[#{index}].sign", adjustment["sign"], ADJUSTMENT_SIGNS)
        validate_optional_inclusion("expected.receipt_adjustments[#{index}].tax_inclusion", adjustment["tax_inclusion"], TAX_INCLUSIONS)
      end
      validate_array("expected.tax_details", expected["tax_details"]) do |tax_detail, index|
        validate_hash("expected.tax_details[#{index}]", tax_detail, required: TAX_DETAIL_REQUIRED_KEYS, allowed: TAX_DETAIL_KEYS)
        validate_inclusion("expected.tax_details[#{index}].basis", tax_detail["basis"], TAX_INCLUSIONS)
      end
      validate_array("expected.payments", expected["payments"]) do |payment, index|
        validate_hash("expected.payments[#{index}]", payment, required: PAYMENT_REQUIRED_KEYS, allowed: PAYMENT_KEYS)
      end
    end

    def validate_amounts
      validate_item_line_totals
      validate_adjustments
      validate_tax_details
      validate_receipt_totals
      validate_payments
      validate_receipt_tax_rate
    end

    def validate_item_line_totals
      expected["items"].each_with_index do |item, index|
        unit_price = decimal(item["unit_price"])
        quantity = decimal(item["quantity"])
        discount = amount(item["discount_amount"])
        computed = unit_price * quantity - discount
        add_error("expected.items[#{index}].line_total", "must equal unit_price * quantity - discount_amount (#{integer_string(computed)})") unless integer_amount?(computed, item["line_total"])
      end
    end

    def validate_adjustments
      expected["receipt_adjustments"].each_with_index do |adjustment, index|
        add_error("expected.receipt_adjustments[#{index}].amount", "must be positive") unless amount(adjustment["amount"]).positive?
        next unless adjustment["effect"] == "purchase"

        add_error("expected.receipt_adjustments[#{index}].tax_rate", "is required for purchase adjustments") if adjustment["tax_rate"].nil?
      end
    end

    def validate_tax_details
      expected["tax_details"].each_with_index do |detail, index|
        net = amount(detail["net"])
        tax = amount(detail["tax"])
        gross = amount(detail["gross"])
        add_error("expected.tax_details[#{index}].gross", "must equal net + tax") unless gross == net + tax

        rate = decimal(detail["rate"])
        computed_tax = if detail["basis"] == "gross"
          round_tax(decimal(gross) * rate / (BigDecimal("1") + rate))
        else
          round_tax(decimal(net) * rate)
        end
        add_error("expected.tax_details[#{index}].tax", "must equal #{computed_tax} for #{detail['basis']} basis") unless tax == computed_tax
      end

      expected_groups = expected_tax_groups
      actual_groups = expected["tax_details"].each_with_object({}) do |detail, groups|
        rate_key = rate_key(detail["rate"])
        groups[rate_key] ||= { "net" => 0, "tax" => 0, "gross" => 0 }
        groups[rate_key]["net"] += amount(detail["net"])
        groups[rate_key]["tax"] += amount(detail["tax"])
        groups[rate_key]["gross"] += amount(detail["gross"])
      end

      expected_groups.each do |rate, values|
        actual = actual_groups[rate] || { "net" => 0, "tax" => 0, "gross" => 0 }
        %w[net tax gross].each do |key|
          add_error("expected.tax_details[rate=#{rate}].#{key}", "must equal computed #{values[key]}") unless actual[key] == values[key]
        end
      end
      extra_rates = actual_groups.keys - expected_groups.keys
      extra_rates.each { |rate| add_error("expected.tax_details", "has unexpected rate #{rate}") }
    end

    def validate_receipt_totals
      net_sum = expected["tax_details"].sum { |detail| amount(detail["net"]) }
      tax_sum = expected["tax_details"].sum { |detail| amount(detail["tax"]) }
      gross_sum = expected["tax_details"].sum { |detail| amount(detail["gross"]) }

      add_error("expected.subtotal", "must equal tax_detail net sum #{net_sum}") unless amount(expected["subtotal"]) == net_sum
      add_error("expected.tax", "must equal tax_detail tax sum #{tax_sum}") unless amount(expected["tax"]) == tax_sum
      add_error("expected.total", "must equal tax_detail gross sum #{gross_sum}") unless amount(expected["total"]) == gross_sum
    end

    def validate_payments
      payment_sum = expected["payments"].sum { |payment| amount(payment["amount"]) }
      add_error("expected.payment_sum", "must equal payments sum #{payment_sum}") unless amount(expected["payment_sum"]) == payment_sum

      due = amount(expected["total"]) + payment_adjustment_total
      add_error("expected.payment_sum", "must equal total plus payment adjustments #{due}") unless payment_sum == due

      settlement = expected["settlement"]
      return if settlement.nil?

      tendered = amount(settlement["tendered"])
      change = amount(settlement["change"])
      actual_cash = expected["payments"].select { |payment| payment["method"] == "cash" }.sum { |payment| amount(payment["amount"]) }
      computed_cash = tendered - change
      add_error("expected.settlement", "tendered - change must equal cash payment #{actual_cash}") unless computed_cash == actual_cash
    end

    def validate_receipt_tax_rate
      rates = expected["tax_details"].filter_map do |detail|
        rate = decimal(detail["rate"])
        rate.zero? ? nil : rate_key(rate)
      end.uniq

      if rates.size == 1
        add_error("expected.tax_rate", "must equal #{rates.first} for a single taxable rate") unless rate_key(expected["tax_rate"]) == rates.first
      elsif rates.size > 1
        add_error("expected.tax_rate", "must be null for multiple taxable rates") unless expected["tax_rate"].nil?
      end
    end

    def expected_tax_groups
      bases = Hash.new { |hash, key| hash[key] = { "net_base" => 0, "gross_base" => 0 } }

      expected["items"].each do |item|
        rate = rate_key(item["tax_rate"])
        inclusion = item["tax_inclusion"] || default_tax_inclusion
        bases[rate]["#{inclusion}_base"] += amount(item["line_total"])
      end

      expected["receipt_adjustments"].select { |adjustment| adjustment["effect"] == "purchase" }.each do |adjustment|
        rate = rate_key(adjustment["tax_rate"])
        inclusion = adjustment["tax_inclusion"] || default_tax_inclusion
        bases[rate]["#{inclusion}_base"] += signed_amount(adjustment)
      end

      bases.each_with_object({}) do |(rate_key, base), groups|
        gross_base = base["gross_base"]
        net_base = base["net_base"]
        rate = decimal_from_rate_key(rate_key)

        if gross_base.positive? && net_base.positive?
          add_error("expected.items", "must not mix gross and net bases within rate #{rate_key}")
          next
        end

        groups[rate_key] = if gross_base.positive?
          tax = round_tax(decimal(gross_base) * rate / (BigDecimal("1") + rate))
          { "gross" => gross_base, "tax" => tax, "net" => gross_base - tax }
        else
          tax = round_tax(decimal(net_base) * rate)
          { "net" => net_base, "tax" => tax, "gross" => net_base + tax }
        end
      end
    end

    def receipt_case?
      case_data["receipt_kind"] == "receipt"
    end

    def expected
      case_data["expected"] || {}
    end

    def default_tax_inclusion
      expected["amount_basis"] == "tax_excluded" ? "net" : "gross"
    end

    def payment_adjustment_total
      expected["receipt_adjustments"].select { |adjustment| adjustment["effect"] == "payment" }.sum { |adjustment| signed_amount(adjustment) }
    end

    def signed_amount(adjustment)
      value = amount(adjustment["amount"])
      adjustment["sign"] == "surcharge" ? value : -value
    end

    def round_tax(value)
      case expected.dig("rounding", "tax")
      when "ceil"
        value.ceil
      when "round"
        value.round(0, :half_up).to_i
      else
        value.floor
      end
    end

    def validate_hash(path, value, required:, allowed:)
      unless value.is_a?(Hash)
        add_error(path, "must be an object")
        return
      end

      missing = required - value.keys
      missing.each { |key| add_error("#{path}.#{key}", "is required") }
      extra = value.keys - allowed
      extra.each { |key| add_error("#{path}.#{key}", "is not allowed") }
    end

    def validate_optional_hash(path, value, allowed:)
      return if value.nil?

      validate_hash(path, value, required: [], allowed: allowed)
    end

    def validate_array(path, value)
      unless value.is_a?(Array)
        add_error(path, "must be an array")
        return
      end

      value.each_with_index { |entry, index| yield entry, index }
    end

    def validate_inclusion(path, value, allowed)
      add_error(path, "must be one of #{allowed.join(', ')}") unless allowed.include?(value)
    end

    def validate_optional_inclusion(path, value, allowed)
      return if value.nil?

      validate_inclusion(path, value, allowed)
    end

    def add_error(path, message)
      errors << "#{path}: #{message}"
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      add_error("amount", "invalid decimal #{value.inspect}")
      BigDecimal("0")
    end

    def amount(value)
      decimal(value).to_i
    end

    def integer_amount?(computed, actual)
      computed.frac.zero? && computed.to_i == amount(actual)
    end

    def integer_string(value)
      value.frac.zero? ? value.to_i.to_s : value.to_s("F")
    end

    def rate_key(value)
      return nil if value.nil?

      decimal(value).to_s("F")
    end

    def decimal_from_rate_key(value)
      BigDecimal(value.to_s)
    end
  end
end
