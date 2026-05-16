module Analysis
  class ReceiptItemNormalizer
    AI_ALLOWED_KEYS = %i[
      index
      position_index
      suggested_name
      category
      needs_review
      tax_rate
      tax_rate_confidence
      tax_rate_reason
    ].freeze

    class << self
      def normalize_ai_item(item)
        new.normalize_ai_item(item)
      end

      def normalize_ai_items(items)
        new.normalize_ai_items(items)
      end
    end

    def normalize_ai_items(items)
      Array(items).map do |item|
        normalize_ai_item(item)
      end.compact
    end

    def normalize_ai_item(item)
      return nil unless item.is_a?(Hash) || item.respond_to?(:to_h)

      raw_item = item.is_a?(Hash) ? item : item.to_h
      normalized = raw_item.with_indifferent_access.slice(*AI_ALLOWED_KEYS)

      result = {
        index: normalize_index(normalized[:index] || normalized[:position_index]),
        suggested_name: normalize_string(normalized[:suggested_name]),
        category: normalize_string(normalized[:category]),
        needs_review: normalize_boolean(normalized[:needs_review]),
        tax_rate: normalize_tax_rate(normalized[:tax_rate]),
        tax_rate_confidence: normalize_confidence(normalized[:tax_rate_confidence]),
        tax_rate_reason: normalize_string(normalized[:tax_rate_reason])
      }.compact

      return nil if result.empty?

      result
    end

    private

    def normalize_index(value)
      return nil if value.blank?
      return value.to_i if value.is_a?(Numeric)

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_string(value)
      text = value.to_s.strip
      text.presence
    end

    def normalize_boolean(value)
      return true if value == true
      return false if value == false
      return nil if value.nil?

      case value.to_s.strip.downcase
      when "true"
        true
      when "false"
        false
      else
        nil
      end
    end

    def normalize_tax_rate(value)
      return nil if value.blank?

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      nil
    end

    def normalize_confidence(value)
      return nil if value.blank?

      confidence = BigDecimal(value.to_s)
      return nil if confidence.negative? || confidence > 1

      confidence
    rescue ArgumentError
      nil
    end
  end
end
