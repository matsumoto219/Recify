module Ai
  class ResponseParser
    REQUIRED_KEYS = %w[
      is_receipt
      document_type
      rejection_reason
      store
      purchase
      payment
      items
      receipt_adjustments
      needs_review
      review_reasons
    ].freeze

    ALLOWED_REVIEW_REASONS = %w[
      store_name_missing
      store_name_uncertain
      store_address_missing
      store_address_uncertain
      store_phone_number_missing
      store_phone_number_uncertain
      purchased_at_missing
      purchased_at_uncertain
      purchased_at_conflicted
      payment_method_missing
      payment_method_uncertain
      items_missing
      item_name_uncertain
      item_category_uncertain
      item_tax_rate_uncertain
      adjustment_uncertain
      ocr_unreadable
      ocr_low_confidence
    ].freeze

    ALLOWED_REJECTION_REASONS = %w[
      no_text
      memo
      article
      screenshot
      presentation
      poster
      shopping_list
      menu
      code_snippet
      unknown_document
      other
    ].freeze

    class << self
      def parse(payload, provider:, meta: {})
        new(payload, provider:, meta:).parse
      end
    end

    def initialize(payload, provider:, meta: {})
      @payload = payload || {}
      @provider = provider
      @meta = meta || {}
    end

    def parse
      normalized_payload = normalize_payload(payload)
      normalized_payload["receipt_adjustments"] ||= []
      validate_payload!(normalized_payload)
      validate_document_classification!(normalized_payload)
      validate_items!(normalized_payload)
      validate_receipt_adjustments!(normalized_payload)
      validate_values!(normalized_payload)

      return not_receipt_result(normalized_payload) unless normalized_payload["is_receipt"]

      Ai::ResultTemplate.success(
        receipt_attributes: normalize_receipt_attributes(normalized_payload),
        receipt_items_attributes: Analysis::ReceiptItemNormalizer.normalize_ai_items(normalized_payload["items"]),
        receipt_adjustments_attributes: normalize_receipt_adjustments(normalized_payload["receipt_adjustments"]),
        needs_review: normalized_payload["needs_review"] == true,
        review_reasons: normalize_review_reasons(normalized_payload["review_reasons"]),
        meta: build_meta(normalized_payload)
      )
    rescue Ai::Errors::ProviderError
      raise
    rescue StandardError => e
      Ai::ResultTemplate.error(
        error_code: "ai_invalid_response",
        review_reasons: [ "response_parse_failed" ],
        meta: error_meta(e)
      )
    end

    private

    attr_reader :payload, :provider, :meta

    def normalize_payload(value)
      return value.deep_stringify_keys if value.is_a?(Hash)

      raise Ai::Errors::ProviderError.new(
        message: "AI payload must be a Hash",
        error_code: "ai_invalid_response",
        provider: provider
      )
    end

    def validate_payload!(normalized_payload)
      missing_keys = REQUIRED_KEYS.reject { |key| normalized_payload.key?(key) }
      return if missing_keys.empty?

      raise Ai::Errors::ProviderError.new(
        message: "Missing required keys: #{missing_keys.join(', ')}",
        error_code: "analysis_missing_keys",
        provider: provider
      )
    end

    def validate_items!(normalized_payload)
      items = normalized_payload["items"]

      unless items.is_a?(Array)
        raise Ai::Errors::ProviderError.new(
          message: "Items must be an Array",
          error_code: "analysis_items_invalid",
          provider: provider
        )
      end

      return if items.all? { |item| item.is_a?(Hash) }

      raise Ai::Errors::ProviderError.new(
        message: "Each item must be a Hash",
        error_code: "analysis_items_invalid",
        provider: provider
      )
    end

    def validate_receipt_adjustments!(normalized_payload)
      adjustments = normalized_payload["receipt_adjustments"]

      unless adjustments.is_a?(Array)
        raise Ai::Errors::ProviderError.new(
          message: "receipt_adjustments must be an Array",
          error_code: "analysis_value_invalid",
          provider: provider
        )
      end

      return if adjustments.all? { |adjustment| adjustment.is_a?(Hash) }

      raise Ai::Errors::ProviderError.new(
        message: "Each receipt_adjustment must be a Hash",
        error_code: "analysis_value_invalid",
        provider: provider
      )
    end

    def validate_values!(normalized_payload)
      validate_needs_review!(normalized_payload["needs_review"])
      validate_review_reasons!(normalized_payload["review_reasons"])
      validate_section_values!(normalized_payload["store"], %w[store_name store_address store_phone_number])
      validate_section_values!(normalized_payload["purchase"], %w[purchased_at_text])
      validate_section_values!(normalized_payload["payment"], %w[payment_method])
    end

    def validate_document_classification!(normalized_payload)
      is_receipt = normalized_payload["is_receipt"]
      unless is_receipt == true || is_receipt == false
        raise Ai::Errors::ProviderError.new(
          message: "is_receipt must be a boolean",
          error_code: "analysis_value_invalid",
          provider: provider
        )
      end

      validate_nullable_string!(normalized_payload["document_type"], "document_type")
      validate_nullable_string!(normalized_payload["rejection_reason"], "rejection_reason")
    end

    def validate_needs_review!(value)
      return if value == true || value == false

      raise Ai::Errors::ProviderError.new(
        message: "needs_review must be a boolean",
        error_code: "analysis_value_invalid",
        provider: provider
      )
    end

    def validate_review_reasons!(value)
      return if value.is_a?(Array)

      raise Ai::Errors::ProviderError.new(
        message: "review_reasons must be an Array",
        error_code: "analysis_value_invalid",
        provider: provider
      )
    end

    def validate_nullable_string!(value, key)
      return if value.nil? || value.is_a?(String)

      raise Ai::Errors::ProviderError.new(
        message: "#{key} must be a String or nil",
        error_code: "analysis_value_invalid",
        provider: provider
      )
    end

    def validate_section_values!(section, allowed_keys)
      return if section.nil?

      unless section.is_a?(Hash)
        raise Ai::Errors::ProviderError.new(
          message: "Section must be a Hash",
          error_code: "analysis_value_invalid",
          provider: provider
        )
      end

      normalized_section = section.deep_stringify_keys

      normalized_section.each do |key, value|
        next unless allowed_keys.include?(key)
        next if value.nil? || value.is_a?(String)

        raise Ai::Errors::ProviderError.new(
          message: "#{key} must be a String or nil",
          error_code: "analysis_value_invalid",
          provider: provider
        )
      end
    end

    def normalize_receipt_attributes(normalized_payload)
      store = normalize_section(normalized_payload["store"])
      purchase = normalize_section(normalized_payload["purchase"])
      payment = normalize_section(normalized_payload["payment"])

      {
        "store_name" => store["store_name"],
        "store_address" => store["store_address"],
        "store_phone_number" => store["store_phone_number"],
        "purchased_at_text" => purchase["purchased_at_text"],
        "payment_method" => payment["payment_method"]
      }.compact
    end

    def normalize_section(section)
      return {} unless section.is_a?(Hash)

      section.deep_stringify_keys
    end

    def build_meta(normalized_payload = nil)
      normalized_meta = {
        provider: provider
      }.merge(meta.deep_symbolize_keys)

      confidence = normalize_is_receipt_confidence(normalized_payload&.fetch("is_receipt_confidence", nil))
      normalized_meta[:is_receipt_confidence] = confidence unless confidence.nil?

      normalized_meta.compact
    end

    def not_receipt_result(normalized_payload)
      Ai::ResultTemplate.error(
        error_code: "ai_not_receipt",
        needs_review: false,
        review_reasons: [],
        meta: build_meta(normalized_payload).merge(
          document_type: normalized_payload["document_type"],
          rejection_reason: normalize_rejection_reason(normalized_payload["rejection_reason"])
        ).compact
      )
    end

    def normalize_is_receipt_confidence(value)
      return nil if value.nil?
      return nil if value.respond_to?(:blank?) && value.blank?

      confidence = Float(value)
      confidence.clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_rejection_reason(value)
      normalized = value.to_s.strip
      return normalized if ALLOWED_REJECTION_REASONS.include?(normalized)

      "unknown_document"
    end

    def error_meta(error)
      {
        provider: provider,
        error_class: error.class.name,
        error_message: error.message
      }.merge(meta.deep_symbolize_keys).compact
    end

    def normalize_review_reasons(reasons)
      Array(reasons)
        .map(&:to_s)
        .map(&:strip)
        .select { |r| ALLOWED_REVIEW_REASONS.include?(r) }
        .uniq
    end

    def normalize_receipt_adjustments(adjustments)
      Array(adjustments).filter_map.with_index do |adjustment, index|
        normalized = adjustment.deep_stringify_keys
        amount = normalize_adjustment_amount(normalized["amount"])
        next if amount.nil?

        kind = normalize_adjustment_kind(normalized["kind"])
        sign = normalize_adjustment_sign(normalized["sign"], kind)
        needs_review = normalized["needs_review"] == true
        review_reasons = normalize_adjustment_review_reasons(normalized["review_reasons"])
        if normalized["kind"].present? && !ReceiptAdjustment::KINDS.include?(normalized["kind"].to_s)
          needs_review = true
          review_reasons << "adjustment_uncertain"
        end
        if normalized["sign"].present? && !ReceiptAdjustment::SIGNS.include?(normalized["sign"].to_s)
          needs_review = true
          review_reasons << "adjustment_uncertain"
        end

        {
          kind: kind,
          label: normalize_short_string(normalized["label"]),
          amount: amount,
          sign: sign,
          tax_rate: normalize_adjustment_tax_rate(normalized["tax_rate"]),
          source_text: normalize_short_string(normalized["source_text"], max_length: 1000),
          source_line_index: normalize_non_negative_integer(normalized["source_line_index"]),
          confidence: normalize_adjustment_confidence(normalized["confidence"]),
          needs_review: needs_review,
          review_reasons: review_reasons.uniq,
          position_index: index + 1
        }.compact
      end
    end

    def normalize_adjustment_kind(value)
      normalized = value.to_s.strip
      return normalized if ReceiptAdjustment::KINDS.include?(normalized)

      "other"
    end

    def normalize_adjustment_sign(value, kind)
      normalized = value.to_s.strip
      return normalized if ReceiptAdjustment::SIGNS.include?(normalized)

      %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].include?(kind) ? "surcharge" : "discount"
    end

    def normalize_adjustment_amount(value)
      amount = Amounts::NumberParser.parse_amount_or_nil(value)
      return nil if amount.nil?

      amount.abs
    end

    def normalize_adjustment_tax_rate(value)
      return nil if value.blank?

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_adjustment_confidence(value)
      return nil if value.blank?

      confidence = BigDecimal(value.to_s)
      return nil if confidence.negative? || confidence > 1

      confidence
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_non_negative_integer(value)
      return nil if value.blank?

      integer = Integer(value)
      integer >= 0 ? integer : nil
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_short_string(value, max_length: 255)
      text = value.to_s.strip
      return nil if text.blank?

      text.first(max_length)
    end

    def normalize_adjustment_review_reasons(reasons)
      Array(reasons).filter_map do |reason|
        normalized = reason.to_s.strip
        normalized.presence
      end
    end
  end
end
