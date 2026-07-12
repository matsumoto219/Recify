class Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer
  class << self
    def items(value)
      Array(value).filter_map.with_index do |item, index|
        symbolized = normalized_attributes(item)
        price = amount(symbolized[:price])
        original_line_total = amount(symbolized[:original_line_total])
        line_total = amount(symbolized[:line_total])
        discount_amount = amount(symbolized[:discount_amount])
        next if [ price, original_line_total, line_total, discount_amount ].compact.any?(&:negative?)
        quantity_unit_code = ReceiptQuantityUnit.normalize(symbolized[:quantity_unit_code])

        {
          raw_text: symbolized[:raw_text].to_s,
          suggested_name: symbolized[:suggested_name].presence,
          confirmed_name: symbolized[:confirmed_name].presence,
          category: symbolized[:category].presence,
          price: price,
          quantity: quantity(symbolized[:quantity]),
          quantity_unit_code: quantity_unit_code,
          product_code: symbolized[:product_code].presence,
          tax_rate: tax_rate(symbolized[:tax_rate]),
          original_line_total: original_line_total,
          line_total: line_total,
          discount_amount: discount_amount,
          discount_rate: tax_rate(symbolized[:discount_rate]),
          # item-level needs_review は前段で決めた値を保持し、この層では再判定しない。
          needs_review: symbolized[:needs_review],
          review_reasons: review_reasons(symbolized[:review_reasons]),
          position_index: symbolized[:position_index] || index + 1,
          confidence: confidence(symbolized[:confidence])
        }
      end
    end

    def adjustments(value)
      Array(value).filter_map.with_index do |adjustment, index|
        symbolized = normalized_attributes(adjustment)
        normalized_amount = amount(symbolized[:amount])
        next unless normalized_amount&.positive?

        kind = symbolized[:kind].to_s
        sign = symbolized[:sign].to_s
        source = symbolized[:source].to_s.presence || "ai"

        {
          kind: ReceiptAdjustment::KINDS.include?(kind) ? kind : "other",
          label: symbolized[:label].to_s.strip.presence,
          amount: normalized_amount.abs,
          sign: ReceiptAdjustment::SIGNS.include?(sign) ? sign : "discount",
          tax_rate: tax_rate(symbolized[:tax_rate]),
          source: ReceiptAdjustment::SOURCES.include?(source) ? source : "ai",
          source_text: symbolized[:source_text].to_s.strip.presence,
          source_line_index: symbolized[:source_line_index],
          confidence: confidence(symbolized[:confidence]),
          needs_review: symbolized[:needs_review] == true,
          review_reasons: review_reasons(symbolized[:review_reasons]),
          position_index: symbolized[:position_index] || index + 1
        }.compact
      end
    end

    def review_reasons(value)
      Array(value).filter_map do |reason|
        normalized = reason.to_s.strip
        normalized.presence
      end.uniq
    end

    def amount(value)
      ReceiptAmountService.parse_amount_or_nil(value)
    end

    def safe_calculated_amount(value)
      normalized_amount = amount(value)
      normalized_amount&.negative? ? nil : normalized_amount
    end

    def quantity(value)
      normalized_quantity = ReceiptAmountService.parse_quantity(value, default: BigDecimal("1"))

      normalized_quantity.positive? ? normalized_quantity : BigDecimal("1")
    end

    def tax_rate(value)
      return nil if value.blank?

      normalized_tax_rate = BigDecimal(value.to_s.delete("%"))
      normalized_tax_rate > 1 ? normalized_tax_rate / 100 : normalized_tax_rate
    rescue ArgumentError
      nil
    end

    def confidence(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    private

    def normalized_attributes(value)
      if value.respond_to?(:with_indifferent_access)
        value.with_indifferent_access
      elsif value.respond_to?(:symbolize_keys)
        value.symbolize_keys.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    end
  end
end
