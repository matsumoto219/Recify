module Ai
  class ResponseParser
    REQUIRED_KEYS = %w[
      store
      purchase
      payment
      items
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
      validate_payload!(normalized_payload)

      Ai::ResultTemplate.success(
        receipt_attributes: normalize_receipt_attributes(normalized_payload),
        receipt_items_attributes: Analysis::ReceiptItemNormalizer.normalize_ai_items(normalized_payload["items"]),
        needs_review: normalized_payload["needs_review"] == true,
        review_reasons: normalize_review_reasons(normalized_payload["review_reasons"]),
        meta: build_meta
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

    def build_meta
      {
        provider: provider
      }.merge(meta.deep_symbolize_keys).compact
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
  end
end
