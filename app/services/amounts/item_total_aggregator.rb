module Amounts
  class ItemTotalAggregator
    include Amounts::QuantityUnitResolver

    def initialize(items:, context: :analysis, rounding_mode: nil, discount_rounding_mode: Amounts::Rounding::DISCOUNT_DEFAULT_MODE)
      @items = Array(items)
      @context = normalize_context(context)
      @discount_rounding_mode = Amounts::Rounding.normalize_rounding_mode(
        discount_rounding_mode || rounding_mode || Amounts::Rounding::DISCOUNT_DEFAULT_MODE
      )
    end

    def call
      normalized = normalized_items

      {
        items: normalized,
        total: normalized.sum { |item| to_i(item[:line_total]) }
      }
    end

    private

    def normalized_items
      @items.map do |item|
        pricing_source_kind = pricing_source_kind_for(item)
        if pricing_source_kind == "reference_quantity_price"
          original_line_total = reference_item_extension_for(item).projected_amount
        elsif pricing_source_kind == "explicit_line_total"
          original_line_total = explicit_line_total_for(item)
        elsif pricing_source_kind == "count_unit_price"
          validate_count_unit_price_source!(item)
          persisted_item = persisted_countable_item(item)
          next persisted_item if persisted_item

          original_line_total = countable_unit_line_total(item)
        else
          persisted_item = persisted_countable_item(item)
          next persisted_item if persisted_item

          original_line_total = original_line_total_for(item)
        end
        submitted_discount_rate = normalize_discount_rate(fetch_value(item, :discount_rate))
        discount_amount = discount_amount_for(item, original_line_total, submitted_discount_rate)
        discount_rate = discount_rate_for(original_line_total, discount_amount, submitted_discount_rate)

        adjusted_line_total = [ original_line_total - discount_amount.to_i, 0 ].max

        item_to_hash(item).merge(
          quantity: normalized_quantity_for(item),
          original_line_total: original_line_total,
          discount_amount: discount_amount,
          discount_rate: discount_rate,
          line_total: adjusted_line_total
        )
      end
    end

    def reference_item_extension_for(item)
      validate_reference_tax_inclusion_for_context!(item)

      Amounts::ReferenceItemExtension.call(
        reference_price_amount: fetch_value(item, :reference_price_amount),
        reference_quantity: fetch_value(item, :reference_quantity),
        reference_unit_code: canonical_reference_unit_code!(
          item,
          code_attribute: :reference_quantity_unit_code,
          raw_attribute: :reference_quantity_unit_raw
        ),
        purchased_quantity: fetch_value(item, :quantity),
        purchased_unit_code: canonical_reference_unit_code!(
          item,
          code_attribute: :quantity_unit_code,
          raw_attribute: :quantity_unit_raw
        ),
        reference_price_tax_inclusion: fetch_value(item, :reference_price_tax_inclusion)
      )
    end

    def canonical_reference_unit_code!(item, code_attribute:, raw_attribute:)
      code = fetch_value(item, code_attribute)
      unit = ReceiptQuantityUnit.unit_for(code)
      raw = fetch_value(item, raw_attribute)
      return code if code.is_a?(String) && unit&.code == code && raw.nil?

      raise Amounts::ItemQuantitySemantics::InvalidFormulaSourceError,
        "reference formula requires canonical unit codes without raw unit evidence"
    end

    def validate_reference_tax_inclusion_for_context!(item)
      return unless @context == :manual

      tax_inclusion = fetch_value(item, :reference_price_tax_inclusion)
      return if tax_inclusion == :gross || tax_inclusion == "gross"

      raise Amounts::ItemPricingSource::InvalidContractError,
        "manual reference formula requires gross tax inclusion"
    end

    def reference_quantity_price_source?(item)
      pricing_source_kind_for(item) == "reference_quantity_price"
    end

    def pricing_source_kind_for(item)
      value = fetch_value(item, :pricing_source_kind)
      return nil if value.nil? || value == ""

      kind = value.to_s
      return kind if ReceiptItem::PRICING_SOURCE_KINDS.include?(kind)

      raise Amounts::ItemPricingSource::InvalidContractError, "unknown item pricing authority kind"
    end

    def explicit_line_total_for(item)
      line_total = fetch_value(item, :line_total)
      unless value_present?(line_total)
        raise Amounts::ItemPricingSource::InvalidContractError,
          "explicit line total authority requires a line total"
      end

      original_line_total = to_i(fetch_value(item, :original_line_total))
      return original_line_total if manual_discount_input?(item) && original_line_total.positive?
      return original_line_total if analysis_context? && original_line_total.positive?

      to_i(line_total)
    end

    def validate_count_unit_price_source!(item)
      unit_code = canonical_reference_unit_code!(
        item,
        code_attribute: :quantity_unit_code,
        raw_attribute: :quantity_unit_raw
      )
      price = fetch_value(item, :price)
      reference_fields_absent = %i[
        reference_price_amount
        reference_quantity
        reference_quantity_unit_code
        reference_quantity_unit_raw
        reference_price_tax_inclusion
      ].all? { |attribute| fetch_value(item, attribute).nil? }
      semantics = Amounts::ItemQuantitySemantics.new(
        purchased_quantity: fetch_value(item, :quantity),
        purchased_unit_code: unit_code
      )

      unless price.is_a?(Integer) && price >= 0 && reference_fields_absent
        raise Amounts::ItemPricingSource::InvalidContractError,
          "count unit price authority requires an integer price without reference evidence"
      end

      semantics.validate_count_formula!
    end

    def original_line_total_for(item)
      # manual/edit_save は現在の入力値が正本。解析時の元値が残っていても再計算の入力にはしない。
      return manual_input_line_total_for(item) if manual_input_context?

      original_line_total = to_i(fetch_value(item, :original_line_total))
      return original_line_total if original_line_total.positive?

      if value_present?(fetch_value(item, :discount_rate))
        unit_total = countable_unit_line_total(item)
        return unit_total if unit_total.positive?
      end

      item_line_total(item)
    end

    def persisted_countable_item(item)
      return nil unless manual_countable_unit_price_input?(item)
      return nil unless fetch_value(item, :amount_persisted_item) == true
      return nil unless fetch_value(item, :amount_countable_source_changed) == false

      line_total = to_i_or_nil(fetch_value(item, :amount_persisted_line_total))
      return nil if line_total.nil?
      return nil unless explainable_persisted_countable_total?(item, line_total)

      item_to_hash(item).merge(
        quantity: normalized_quantity_for(item),
        original_line_total: to_i_or_nil(fetch_value(item, :amount_persisted_original_line_total)),
        discount_amount: to_i_or_nil(fetch_value(item, :amount_persisted_discount_amount)),
        discount_rate: normalize_discount_rate(fetch_value(item, :amount_persisted_discount_rate)),
        line_total: line_total
      )
    end

    def explainable_persisted_countable_total?(item, line_total)
      unit_total = countable_unit_line_total(item)
      return true if line_total == unit_total

      original_line_total = to_i_or_nil(fetch_value(item, :amount_persisted_original_line_total))
      return false unless original_line_total == unit_total
      return true if value_present?(fetch_value(item, :amount_persisted_discount_rate))
      return true if value_present?(fetch_value(item, :amount_persisted_discount_amount))

      line_total >= original_line_total
    end

    def manual_input_line_total_for(item)
      if manual_countable_unit_price_input?(item)
        unit_total = countable_unit_line_total(item)
        return unit_total if countable_source_recalculation_required?(item)
        return unit_total if manual_discount_input?(item)

        original_line_total = to_i(fetch_value(item, :original_line_total))
        return normalized_saved_line_total_for(item, unit_total) || unit_total
      end

      original_line_total = to_i(fetch_value(item, :original_line_total))
      return original_line_total if manual_discount_input?(item) && original_line_total.positive?

      line_total_value = fetch_value(item, :line_total)
      return to_i(line_total_value) if value_present?(line_total_value)

      0
    end

    def manual_discount_input?(item)
      value_present?(fetch_value(item, :discount_rate)) ||
        value_present?(fetch_value(item, :discount_amount)) ||
        fetch_value(item, :amount_discount_amount_present) == true
    end

    def normalized_saved_line_total_for(item, unit_total)
      return nil if value_present?(fetch_value(item, :discount_rate))
      return nil if to_i(fetch_value(item, :discount_amount)).positive?

      original_line_total = to_i(fetch_value(item, :original_line_total))
      line_total = to_i(fetch_value(item, :line_total))
      return nil unless original_line_total.positive? && line_total.positive?
      return nil if original_line_total == line_total
      return nil unless unit_total == original_line_total

      line_total
    end

    def item_to_hash(item)
      if item.respond_to?(:attributes)
        item.attributes.symbolize_keys
      elsif item.respond_to?(:to_h)
        item.to_h.symbolize_keys
      else
        {}
      end
    end

    def item_line_total(item)
      return countable_unit_line_total(item) if manual_countable_unit_price_input?(item)

      line_total_value = fetch_value(item, :line_total)
      return to_i(line_total_value) if value_present?(line_total_value)

      countable_unit_line_total(item)
    end

    def countable_unit_line_total(item)
      return 0 unless countable_quantity_unit_for_item?(item)

      price = to_amount_decimal(fetch_value(item, :price))
      round_amount(price * normalized_quantity_for(item))
    end

    def discount_amount_for(item, original_line_total, submitted_discount_rate)
      explicit_discount_amount = to_i_or_nil(fetch_value(item, :discount_amount))
      return explicit_discount_amount if analysis_context? && discount_amount_input_present?(item)

      if !submitted_discount_rate.nil?
        return 0 unless original_line_total.positive?

        return Amounts::Rounding.apply_rounding(
          BigDecimal(original_line_total.to_s) * submitted_discount_rate,
          @discount_rounding_mode
        )
      end

      return explicit_discount_amount if manual_input_context? && manual_discount_amount_input_present?(item)

      manual_input_context? ? nil : (discount_amount_input_present?(item) ? explicit_discount_amount : nil)
    end

    def discount_rate_for(original_line_total, discount_amount, submitted_discount_rate)
      return submitted_discount_rate unless submitted_discount_rate.nil?
      return nil unless discount_amount.to_i.positive?
      return nil unless original_line_total.positive?
      return nil if discount_amount.to_i > original_line_total

      BigDecimal(discount_amount.to_i.to_s) / BigDecimal(original_line_total.to_s)
    end

    def normalized_quantity_for(item)
      quantity = to_decimal(fetch_value(item, :quantity))
      return quantity if manual_input_context? && quantity_input_present?(item)

      quantity.positive? ? quantity : BigDecimal("1")
    end

    def fetch_value(item, key)
      if item.is_a?(Hash)
        return item[key] if item.key?(key)
        return item[key.to_s] if item.key?(key.to_s)

        return nil
      end

      return item[key] || item[key.to_s] if item.respond_to?(:[])
      return item.public_send(key) if item.respond_to?(key)

      nil
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def to_i_or_nil(value)
      Amounts::NumberParser.parse_amount_or_nil(value)
    end

    def to_decimal(value)
      Amounts::NumberParser.parse_quantity(value)
    end

    def to_amount_decimal(value)
      BigDecimal(to_i(value).to_s)
    end

    def normalize_discount_rate(value)
      return nil unless value_present?(value)

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      nil
    end

    def round_amount(value)
      BigDecimal(value.to_s).round(0).to_i
    end

    def manual_countable_unit_price_input?(item)
      manual_input_context? &&
        countable_quantity_unit_for_item?(item) &&
        value_present?(fetch_value(item, :price))
    end

    def normalize_context(value)
      context = value.to_s.to_sym
      %i[analysis edit_save manual].include?(context) ? context : :analysis
    end

    def analysis_context?
      @context == :analysis
    end

    def manual_input_context?
      %i[edit_save manual].include?(@context)
    end

    def discount_amount_input_present?(item)
      value_present?(fetch_value(item, :discount_amount))
    end

    def manual_discount_amount_input_present?(item)
      flag = fetch_value(item, :amount_discount_amount_present)
      return flag if flag == true || flag == false

      false
    end

    def quantity_input_present?(item)
      flag = fetch_value(item, :amount_quantity_present)
      return flag if flag == true || flag == false

      value_present?(fetch_value(item, :quantity))
    end

    def countable_source_recalculation_required?(item)
      source_changed = fetch_value(item, :amount_countable_source_changed)
      return source_changed if source_changed == true || source_changed == false

      presence_flags = %i[amount_price_present amount_quantity_present amount_line_total_present].map do |key|
        fetch_value(item, key)
      end
      return presence_flags.any?(true) if presence_flags.any? { |flag| flag == true || flag == false }

      value_present?(fetch_value(item, :price)) || value_present?(fetch_value(item, :quantity))
    end

    def value_present?(value)
      !value.nil? && value != ""
    end
  end
end
