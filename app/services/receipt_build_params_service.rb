class ReceiptBuildParamsService
  class << self
    def call(ocr_result:, ai_result: nil)
      candidates = normalize_candidates(ocr_result)
      normalized_ai_result = normalize_ai_result(ai_result)

      {
        receipt_attributes: build_receipt_attributes(candidates, normalized_ai_result[:receipt_attributes]),
        receipt_items_attributes: build_receipt_items_attributes(candidates, normalized_lines(ocr_result), normalized_ai_result[:receipt_items_attributes]),
        receipt_payments_attributes: build_receipt_payments_attributes(candidates),
        receipt_tax_details_attributes: build_receipt_tax_details_attributes(candidates)
      }
    end

    private

    def normalize_candidates(ocr_result)
      (ocr_result[:candidates] || {}).deep_symbolize_keys
    end

    def normalized_lines(ocr_result)
      Array(ocr_result[:lines]).map(&:to_s)
    end

    def normalize_ai_result(ai_result)
      return { receipt_attributes: {}, receipt_items_attributes: [] } unless ai_result.is_a?(Hash)

      symbolized = ai_result.deep_symbolize_keys

      {
        receipt_attributes: symbolized[:receipt_attributes] || {},
        receipt_items_attributes: Array(symbolized[:receipt_items_attributes])
      }
    end

    def build_receipt_attributes(candidates, ai_receipt_attributes)
      ai_attrs = normalize_receipt_attributes(ai_receipt_attributes)

      {
        store_name: ai_attrs[:store_name].presence || candidates[:store_name],
        store_address: ai_attrs[:store_address].presence || candidates[:store_address],
        store_phone_number: ai_attrs[:store_phone_number].presence || candidates[:store_phone_number],
        purchased_at: ai_attrs[:purchased_at].presence || parse_purchased_at(ai_attrs[:purchased_at_text]) || parse_purchased_at(candidates[:purchased_at_text]),
        total_amount: ai_attrs[:total_amount] || normalize_amount(candidates[:total_amount]),
        subtotal_amount: ai_attrs[:subtotal_amount] || normalize_amount(candidates[:subtotal_amount]),
        tax_amount: ai_attrs[:tax_amount] || normalize_amount(candidates[:tax_amount]),
        tax_rate: ai_attrs[:tax_rate] || normalize_rate(candidates[:tax_rate]),
        tip_amount: ai_attrs[:tip_amount] || normalize_amount(candidates[:tip_amount]),
        country_region: ai_attrs[:country_region].presence || candidates[:country_region],
        receipt_type: ai_attrs[:receipt_type].presence || candidates[:receipt_type],
        payment_method: ai_attrs[:payment_method].presence || detect_payment_method(candidates),
        processing_error_code: ai_attrs[:processing_error_code],
        processing_error_message: ai_attrs[:processing_error_message],
        ocr_completed_at: ai_attrs[:ocr_completed_at]
      }.compact
    end

    def build_receipt_items_attributes(candidates, lines, ai_items)
      candidate_items = Array(candidates[:items])
      normalized_ai_items = normalize_items(ai_items)

      source_items = if candidate_items.present?
        if normalized_ai_items.present?
          merge_items(candidate_items, normalized_ai_items)
        else
          candidate_items
        end
      else
        fallback_items = build_items_from_lines(lines)

        if normalized_ai_items.present?
          merge_items(fallback_items, normalized_ai_items)
        else
          fallback_items
        end
      end

      source_items.each_with_index.map do |item, index|
        normalized_item = item.respond_to?(:deep_symbolize_keys) ? item.deep_symbolize_keys : {}
        raw_text = normalized_item[:raw_text].to_s
        price = normalize_amount(normalized_item[:price])
        quantity = normalize_quantity(normalized_item[:quantity])

        {
          # Azure Items[].Description / Name -> receipt_items.raw_text
          raw_text: raw_text,
          suggested_name: normalized_item[:suggested_name].presence || extract_item_name(raw_text),
          confirmed_name: normalized_item[:confirmed_name],
          category: normalized_item[:category].presence || detect_category(raw_text),
          price: price,
          quantity: quantity,
          # Azure Items[].QuantityUnit -> receipt_items.quantity_unit
          quantity_unit: normalized_item[:quantity_unit],
          # Azure Items[].ProductCode -> receipt_items.product_code
          product_code: normalized_item[:product_code],
          line_total: normalize_amount(normalized_item[:line_total]) || extract_item_line_total(raw_text, price:, quantity:),
          needs_review: normalized_item.key?(:needs_review) ? normalized_item[:needs_review] : true,
          position_index: normalized_item[:position_index] || index + 1,
          confidence: normalize_confidence(normalized_item[:confidence])
        }
      end
    end

    def build_receipt_payments_attributes(candidates)
      Array(candidates[:payments]).map do |payment|
        normalized_payment = payment.respond_to?(:deep_symbolize_keys) ? payment.deep_symbolize_keys : {}

        {
          # Azure Payments[].Method -> receipt_payments.method
          method: normalized_payment[:method],
          # Azure Payments[].Amount -> receipt_payments.amount
          amount: normalize_amount(normalized_payment[:amount])
        }.compact
      end
    end

    def build_receipt_tax_details_attributes(candidates)
      Array(candidates[:tax_details]).map do |tax_detail|
        normalized_tax_detail = tax_detail.respond_to?(:deep_symbolize_keys) ? tax_detail.deep_symbolize_keys : {}

        {
          # Azure TaxDetails[].Description -> receipt_tax_details.description
          description: normalized_tax_detail[:description],
          # Azure TaxDetails[].Amount -> receipt_tax_details.amount
          amount: normalize_amount(normalized_tax_detail[:amount]),
          # Azure TaxDetails[].Rate -> receipt_tax_details.rate
          rate: normalize_rate(normalized_tax_detail[:rate]),
          # Azure TaxDetails[].NetAmount -> receipt_tax_details.net_amount
          net_amount: normalize_amount(normalized_tax_detail[:net_amount])
        }.compact
      end
    end

    def normalize_receipt_attributes(attributes)
      return {} unless attributes.is_a?(Hash)

      symbolized = attributes.deep_symbolize_keys

      {
        store_name: symbolized[:store_name],
        store_address: symbolized[:store_address],
        store_phone_number: symbolized[:store_phone_number],
        purchased_at: symbolized[:purchased_at],
        purchased_at_text: symbolized[:purchased_at_text],
        total_amount: normalize_amount(symbolized[:total_amount]),
        subtotal_amount: normalize_amount(symbolized[:subtotal_amount]),
        tax_amount: normalize_amount(symbolized[:tax_amount]),
        tax_rate: normalize_rate(symbolized[:tax_rate]),
        tip_amount: normalize_amount(symbolized[:tip_amount]),
        country_region: symbolized[:country_region],
        receipt_type: symbolized[:receipt_type],
        payment_method: symbolized[:payment_method],
        processing_error_code: symbolized[:processing_error_code],
        processing_error_message: symbolized[:processing_error_message],
        ocr_completed_at: symbolized[:ocr_completed_at]
      }.compact
    end

    def normalize_items(items)
      Array(items).map do |item|
        item.respond_to?(:deep_symbolize_keys) ? item.deep_symbolize_keys : {}
      end
    end

    def merge_items(candidate_items, ai_items)
      max_size = [ candidate_items.size, ai_items.size ].max

      Array.new(max_size) do |index|
        candidate_item = candidate_items[index].respond_to?(:deep_symbolize_keys) ? candidate_items[index].deep_symbolize_keys : {}
        ai_item = ai_items[index].respond_to?(:deep_symbolize_keys) ? ai_items[index].deep_symbolize_keys : {}

        candidate_item.merge(ai_item.compact).merge(
          quantity_unit: ai_item[:quantity_unit].presence || candidate_item[:quantity_unit],
          product_code: ai_item[:product_code].presence || candidate_item[:product_code]
        )
      end
    end

    def build_items_from_lines(lines)
      Array(lines).select { |line| item_line?(line) }.each_with_index.map do |line, index|
        price = extract_item_price(line)
        quantity = extract_item_quantity(line)

        {
          raw_text: line,
          suggested_name: extract_item_name(line),
          confirmed_name: nil,
          category: detect_category(line),
          price: price,
          quantity: quantity,
          quantity_unit: nil,
          product_code: nil,
          line_total: extract_item_line_total(line, price:, quantity:),
          needs_review: true,
          position_index: index + 1,
          confidence: BigDecimal("0.3")
        }
      end
    end

    def item_line?(line)
      return false if line.blank?
      return false if line.include?("合計")
      return false if line.match?(%r{\d{4}[\/-]\d{1,2}[\/-]\d{1,2}})
      return false if line.match?(/現金|cash|visa|master|mastercard|jcb|amex|american express|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakuten pay|d払い|au pay|メルペイ|line pay|デビット|debit/i)

      line.match?(/\S+.*\d+/)
    end

    def extract_item_price(line)
      numbers = line.to_s.scan(/\d+/)
      return nil if numbers.empty?

      numbers.first.to_i
    end

    def extract_item_quantity(line)
      quantity_match = line.to_s.match(/[x×](\d+)/i)
      return quantity_match[1].to_i if quantity_match

      1
    end

    def detect_payment_method(candidates)
      detected = ReceiptFallbackPatterns.detect_payment_method(candidates[:payment_method_text])
      detected == "other" ? nil : detected
    end

    def detect_category(text)
      ReceiptFallbackPatterns.detect_category(text)
    end

    def parse_purchased_at(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_amount(value)
      return nil if value.blank?
      return value.to_i if value.is_a?(Numeric)

      digits = value.to_s.scan(/\d+/).join
      digits.present? ? digits.to_i : nil
    end

    def normalize_rate(value)
      return nil if value.blank?
      return value.to_d if value.is_a?(Numeric)

      cleaned = value.to_s.delete("%")
      cleaned.present? ? cleaned.to_d : nil
    rescue ArgumentError
      nil
    end

    def normalize_quantity(value)
      return 1 if value.blank?
      return value.to_i if value.is_a?(Numeric)

      quantity = value.to_s.scan(/\d+/).join
      quantity.present? ? quantity.to_i : 1
    end

    def normalize_confidence(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def extract_item_name(line)
      line.to_s.sub(/\s+\d.*$/, "").strip
    end

    def extract_item_line_total(line, price:, quantity:)
      return nil unless price

      price * quantity.to_i
    end
  end
end
