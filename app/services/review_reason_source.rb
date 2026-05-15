# frozen_string_literal: true

module ReviewReasonSource
  AI_REASONS = %w[
    item_name_uncertain
    item_category_uncertain
    item_tax_rate_uncertain
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
  ].freeze

  OCR_REASONS = %w[
    ocr_unreadable
    ocr_low_confidence
  ].freeze

  AMOUNT_REASONS = %w[
    total_mismatch
    item_total_mismatch
    tax_amount_mismatch
    tax_detail_mismatch
    tax_detail_rate_mismatch
    tax_detail_incomplete
    tax_detail_partial
    ocr_total_mismatch
    zero_amount_item_incomplete
    discount_data_incomplete
    price_tax_inclusion_uncertain
    calculation_profile_uncertain
    insufficient_data
  ].freeze

  SYSTEM_REASONS = %w[
    ai_api_error
    ai_timeout
    unexpected_error
    response_parse_failed
    analysis_missing_keys
    analysis_items_invalid
    analysis_value_invalid
    ai_invalid_response
    ai_primary_failed
    ai_fallback_failed
  ].freeze

  WARNING_REASONS = (
    Amounts::MismatchSeverity::WARNING.map(&:to_s) +
    %w[ocr_low_confidence]
  ).freeze

  SOURCES = %i[
    ai
    ocr
    amount
    system
    unknown
  ].freeze

  module_function

  def source_for(reason)
    normalized = normalize(reason)

    return :ai if AI_REASONS.include?(normalized)
    return :ocr if OCR_REASONS.include?(normalized)
    return :amount if AMOUNT_REASONS.include?(normalized)
    return :system if SYSTEM_REASONS.include?(normalized)

    :unknown
  end

  def group_by_source(reasons)
    SOURCES.index_with { [] }.tap do |groups|
      Array(reasons).each do |reason|
        groups[source_for(reason)] << normalize(reason)
      end
    end
  end

  def review_reasons_for_user(reasons)
    Array(reasons).filter_map do |reason|
      normalized = normalize(reason)
      next if normalized.blank?
      next if source_for(normalized) == :system

      normalized
    end.uniq
  end

  def warning_reason?(reason)
    WARNING_REASONS.include?(normalize(reason))
  end

  def blocking_reason?(reason)
    normalized = normalize(reason)
    normalized.present? &&
      source_for(normalized) != :system &&
      !warning_reason?(normalized)
  end

  def warning_reasons_for_user(reasons)
    review_reasons_for_user(reasons).select { |reason| warning_reason?(reason) }
  end

  def blocking_reasons_for_user(reasons)
    review_reasons_for_user(reasons).select { |reason| blocking_reason?(reason) }
  end

  def internal_processing_reasons(reasons)
    Array(reasons).filter_map do |reason|
      normalized = normalize(reason)
      next if normalized.blank?
      next unless source_for(normalized) == :system

      normalized
    end.uniq
  end

  def normalize(reason)
    reason.to_s.strip
  end
end
