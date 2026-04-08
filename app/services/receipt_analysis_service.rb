class ReceiptAnalysisService
  class AnalysisError < StandardError
    attr_reader :error_code

    def initialize(error_code, message = nil)
      @error_code = error_code
      super(message)
    end
  end

  UNREADABLE_CONFIDENCE_THRESHOLD = 0.3
  REVIEW_NEEDED_CONFIDENCE_THRESHOLD = 0.6
  OCR_ENABLED_ENV_KEY = "RECEIPT_OCR_ENABLED"
  AI_ENABLED_ENV_KEY = "RECEIPT_AI_ENABLED"

  def self.call(receipt)
    new(receipt).call
  end

  def initialize(receipt)
    @receipt = receipt
  end

  def call
    Rails.logger.info("[ReceiptAnalysis] start receipt_id=#{receipt.id}")

    mark_processing!

    unless ocr_enabled?
      Rails.logger.warn("[ReceiptAnalysis] ocr_disabled receipt_id=#{receipt.id}")
      return fail_receipt!("ocr_disabled")
    end

    ocr_result = ReceiptOcrService.call(receipt.image)
    log_ocr_result(ocr_result)

    unless ocr_result[:success]
      return fail_receipt!(ocr_result[:error_code].presence || "ocr_api_error")
    end

    if unreadable_ocr?(ocr_result)
      Rails.logger.warn("[ReceiptAnalysis] ocr_unreadable receipt_id=#{receipt.id}")
      return fail_receipt!("ocr_unreadable")
    end

    unless ai_enabled?
      Rails.logger.info("[ReceiptAnalysis] ai_disabled_ocr_only receipt_id=#{receipt.id}")
      return save_ocr_only_result!(ocr_result)
    end

    ai_result = run_ai_enrichment(ocr_result)

    if ai_result[:success]
      save_ai_result!(ocr_result, ai_result)
    else
      save_fallback_result!(ocr_result, ai_result[:error_code].presence || "ai_invalid_response")
    end
  rescue AnalysisError
    raise
  rescue StandardError => e
    Rails.logger.error(
      "[ReceiptAnalysis] unexpected_error receipt_id=#{receipt.id} error_class=#{e.class} message=#{e.message}"
    )
    fail_receipt!("unexpected_error", e.message)
    raise AnalysisError.new("unexpected_error", e.message)
  end

  private

  attr_reader :receipt

  def mark_processing!
    receipt.update!(status: "processing", processing_error_code: nil, processing_error_message: nil)
  end

  def log_ocr_result(ocr_result)
    Rails.logger.info(
      "[ReceiptAnalysis] ocr_result receipt_id=#{receipt.id} success=#{ocr_result[:success]} lines=#{ocr_result[:lines]&.size || 0} error_code=#{ocr_result[:error_code]}"
    )
  end

  def ocr_enabled?
    ActiveModel::Type::Boolean.new.cast(
      ENV.fetch(OCR_ENABLED_ENV_KEY, "true")
    )
  end

  def ai_enabled?
    ActiveModel::Type::Boolean.new.cast(
      ENV.fetch(AI_ENABLED_ENV_KEY, "true")
    )
  end

  def run_ai_enrichment(ocr_result)
    ai_result = ReceiptAiEnrichmentService.call(ocr_result)
    normalized = normalize_ai_result(ai_result)

    Rails.logger.info(
      "[ReceiptAnalysis] ai_result receipt_id=#{receipt.id} success=#{normalized[:success]} error_code=#{normalized[:error_code]}"
    )

    normalized
  rescue ReceiptAiEnrichmentService::AiEnrichmentError => e
    Rails.logger.warn(
      "[ReceiptAnalysis] ai_failed_fallback receipt_id=#{receipt.id} error_code=#{e.error_code} message=#{e.message}"
    )
    { success: false, error_code: e.error_code }
  end

  def normalize_ai_result(result)
    return { success: false, error_code: "ai_invalid_response" } unless result.is_a?(Hash)

    symbolized = result.symbolize_keys

    # (receipt_attributesを含む構造)のみ受け付ける
    unless symbolized[:receipt_attributes].is_a?(Hash)
      return { success: false, error_code: "ai_invalid_response" }
    end

    # receipt_items_attributes が無い場合は空配列で扱う
    symbolized[:receipt_items_attributes] ||= []

    {
      success: symbolized.key?(:success) ? symbolized[:success] : true,
      error_code: symbolized[:error_code],
      needs_review: symbolized[:needs_review],
      receipt_attributes: symbolized[:receipt_attributes].symbolize_keys,
      receipt_items_attributes: Array(symbolized[:receipt_items_attributes]).map do |item|
        normalized_item = item.respond_to?(:symbolize_keys) ? item.symbolize_keys : {}
        {
          raw_text: normalized_item[:raw_text],
          suggested_name: normalized_item[:suggested_name],
          confirmed_name: normalized_item[:confirmed_name],
          category: normalized_item[:category],
          price: normalized_item[:price],
          quantity: normalized_item[:quantity],
          quantity_unit: normalized_item[:quantity_unit],
          product_code: normalized_item[:product_code],
          line_total: normalized_item[:line_total],
          needs_review: normalized_item.key?(:needs_review) ? normalized_item[:needs_review] : true,
          position_index: normalized_item[:position_index],
          confidence: normalized_item[:confidence]
        }
      end
    }
  end

  def unreadable_ocr?(ocr_result)
    candidates = ocr_candidates(ocr_result)
    raw_text = ocr_result[:raw_text].to_s
    items = Array(candidates[:items])
    overall_confidence = candidates.dig(:confidence_summary, :overall)

    return true if raw_text.blank?
    return true if items.blank? && candidates[:store_name].blank? && candidates[:total_amount].blank?
    return true if overall_confidence.present? && overall_confidence.to_f < UNREADABLE_CONFIDENCE_THRESHOLD

    false
  end

  def low_quality_ocr?(ocr_result, receipt_attributes:)
    candidates = ocr_candidates(ocr_result)
    items = Array(candidates[:items])
    items_average = candidates.dig(:confidence_summary, :items_average)

    return true if candidates[:store_name].blank?
    return true if candidates[:total_amount].blank?
    return true if items.blank?
    # OCRにもAIにも決済情報がない場合のみ review_needed
    return true if candidates[:payment_method_text].blank? && receipt_attributes[:payment_method].blank?
    return true if items_average.present? && items_average.to_f < REVIEW_NEEDED_CONFIDENCE_THRESHOLD
    # OCR品質判定ではAI後のロジックは使わない（rawデータ基準）
    return true if items.any? { |item| item[:raw_text].blank? }
    return true if items.any? { |item| item[:confidence].present? && item[:confidence].to_f < REVIEW_NEEDED_CONFIDENCE_THRESHOLD }

    false
  end

  def save_ai_result!(ocr_result, ai_result)
    params = ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: ai_result)

    final_status = determine_final_status(
      ocr_result: ocr_result,
      receipt_attributes: params[:receipt_attributes],
      items_attributes: params[:receipt_items_attributes],
      ai_needs_review: ai_result[:needs_review]
    )

    persist_result_full!(
      receipt_attributes: params[:receipt_attributes].merge(
        status: final_status,
        processing_error_code: nil,
        processing_error_message: nil,
        ocr_completed_at: Time.current
      ),
      items_attributes: params[:receipt_items_attributes],
      payments_attributes: params[:receipt_payments_attributes],
      tax_details_attributes: params[:receipt_tax_details_attributes]
    )

    Rails.logger.info(
      "[ReceiptAnalysis] completed receipt_id=#{receipt.id} status=#{final_status} items=#{params[:receipt_items_attributes].size}"
    )

    receipt
  end

  def save_ocr_only_result!(ocr_result)
    params = ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)

    final_status = determine_final_status(
      ocr_result: ocr_result,
      receipt_attributes: params[:receipt_attributes],
      items_attributes: params[:receipt_items_attributes],
      ai_needs_review: false
    )

    persist_result_full!(
      receipt_attributes: params[:receipt_attributes].merge(
        status: final_status,
        processing_error_code: nil,
        processing_error_message: nil,
        ocr_completed_at: Time.current
      ),
      items_attributes: params[:receipt_items_attributes],
      payments_attributes: params[:receipt_payments_attributes],
      tax_details_attributes: params[:receipt_tax_details_attributes]
    )

    Rails.logger.info(
      "[ReceiptAnalysis] ocr_only_completed receipt_id=#{receipt.id} status=#{final_status} items=#{params[:receipt_items_attributes].size}"
    )

    receipt
  end

  def save_fallback_result!(ocr_result, error_code)
    params = ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)

    receipt_attributes = params[:receipt_attributes].merge(
      status: "review_needed",
      processing_error_code: error_code,
      processing_error_message: nil,
      ocr_completed_at: Time.current
    )

    persist_result_full!(
      receipt_attributes: receipt_attributes,
      items_attributes: params[:receipt_items_attributes],
      payments_attributes: params[:receipt_payments_attributes],
      tax_details_attributes: params[:receipt_tax_details_attributes]
    )

    Rails.logger.warn(
      "[ReceiptAnalysis] fallback_saved receipt_id=#{receipt.id} error_code=#{error_code} items=#{params[:receipt_items_attributes].size}"
    )

    receipt
  end

  def fail_receipt!(error_code, message = nil)
    mapped = ReceiptProcessingErrorMapper.map(error_code)

    receipt.update!(
      status: "failed",
      processing_error_code: mapped[:error_code],
      processing_error_message: message,
      ocr_completed_at: Time.current
    )

    Rails.logger.error(
      "[ReceiptAnalysis] failed receipt_id=#{receipt.id} error_code=#{error_code} message=#{message}"
    )

    receipt
  end

  def persist_result_full!(receipt_attributes:, items_attributes:, payments_attributes:, tax_details_attributes:)
    Receipt.transaction do
      receipt.update!(receipt_attributes)

      replace_receipt_items!(items_attributes)

      receipt.receipt_payments.destroy_all
      Array(payments_attributes).each do |attrs|
        receipt.receipt_payments.create!(attrs)
      end

      receipt.receipt_tax_details.destroy_all
      Array(tax_details_attributes).each do |attrs|
        receipt.receipt_tax_details.create!(attrs)
      end
    end
  end

  def replace_receipt_items!(items_attributes)
    receipt.receipt_items.destroy_all

    normalize_items_attributes(items_attributes).each_with_index do |item_attributes, index|
      receipt.receipt_items.create!(
        item_attributes.merge(position_index: item_attributes[:position_index] || index + 1)
      )
    end
  end

  def determine_final_status(ocr_result:, receipt_attributes:, items_attributes:, ai_needs_review: nil)
    return "review_needed" if ai_needs_review
    return "review_needed" if low_quality_ocr?(ocr_result, receipt_attributes: receipt_attributes)
    return "review_needed" if receipt_attributes[:store_name].blank?
    return "review_needed" if receipt_attributes[:total_amount].blank?
    return "review_needed" if receipt_attributes[:payment_method].blank?
    return "review_needed" if items_attributes.blank?
    return "review_needed" if items_attributes.any? { |item| item_needs_review?(item) }

    "completed"
  end

  def build_receipt_attributes_from_ocr(ocr_result)
    candidates = ocr_candidates(ocr_result)

    {
      store_name: candidates[:store_name],
      store_address: candidates[:store_address],
      store_phone_number: candidates[:store_phone_number],
      purchased_at: parse_purchased_at(candidates[:purchased_at_text]),
      total_amount: normalize_amount(candidates[:total_amount]),
      subtotal_amount: normalize_amount(candidates[:subtotal_amount]),
      tax_amount: normalize_amount(candidates[:tax_amount]),
      payment_method: detect_payment_method(candidates[:payment_method_text])
    }.compact
  end

  def build_items_from_ocr(ocr_result)
    candidates = ocr_candidates(ocr_result)
    candidate_items = Array(candidates[:items])

    items = if candidate_items.present?
      candidate_items.each_with_index.map do |item, index|
        normalized_item = item.respond_to?(:symbolize_keys) ? item.symbolize_keys : {}
        raw_text = normalized_item[:raw_text].to_s
        {
          raw_text: raw_text,
          suggested_name: extract_item_name(raw_text),
          confirmed_name: nil,
          category: detect_category(raw_text),
          price: normalize_amount(normalized_item[:price]),
          quantity: normalize_quantity(normalized_item[:quantity]),
          line_total: normalize_amount(normalized_item[:line_total]),
          needs_review: true,
          position_index: index + 1,
          confidence: normalize_confidence(normalized_item[:confidence])
        }
      end
    else
      build_items_from_lines(ocr_result[:lines])
    end

    items.presence || build_items_from_lines(ocr_result[:lines])
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
        line_total: extract_item_line_total(line, price:, quantity:),
        needs_review: true,
        position_index: index + 1,
        confidence: BigDecimal("0.3")
      }
    end
  end

  def normalize_receipt_attributes(attributes)
    return {} unless attributes.is_a?(Hash)

    symbolized = attributes.symbolize_keys

    {
      store_name: symbolized[:store_name],
      store_address: symbolized[:store_address],
      store_phone_number: symbolized[:store_phone_number],
      purchased_at: symbolized[:purchased_at].presence || parse_purchased_at(symbolized[:purchased_at_text]),
      total_amount: normalize_amount(symbolized[:total_amount]),
      subtotal_amount: normalize_amount(symbolized[:subtotal_amount]),
      tax_amount: normalize_amount(symbolized[:tax_amount]),
      tip_amount: normalize_amount(symbolized[:tip_amount]),
      payment_method: symbolized[:payment_method]
    }.compact
  end

  def normalize_items_attributes(items)
    Array(items).map.with_index do |item, index|
      symbolized = item.respond_to?(:symbolize_keys) ? item.symbolize_keys : {}
      raw_text = symbolized[:raw_text].to_s
      price = normalize_amount(symbolized[:price])
      quantity = normalize_quantity(symbolized[:quantity])

      {
        raw_text: raw_text,
        suggested_name: symbolized[:suggested_name].presence || extract_item_name(raw_text),
        confirmed_name: symbolized[:confirmed_name],
        category: symbolized[:category].presence || detect_category(raw_text),
        price: price,
        quantity: quantity,
        quantity_unit: symbolized[:quantity_unit],
        product_code: symbolized[:product_code],
        line_total: normalize_amount(symbolized[:line_total]) || extract_item_line_total(raw_text, price:, quantity:),
        needs_review: symbolized.key?(:needs_review) ? symbolized[:needs_review] : true,
        position_index: symbolized[:position_index] || index + 1,
        confidence: normalize_confidence(symbolized[:confidence])
      }
    end
  end

  def ocr_candidates(ocr_result)
    (ocr_result[:candidates] || {}).deep_symbolize_keys
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

  def item_needs_review?(item_attributes)
    confidence = normalize_confidence(item_attributes[:confidence])

    return true if item_attributes[:raw_text].blank?
    return true if item_attributes[:category].blank?
    return true if item_attributes[:line_total].blank?
    return true if confidence.present? && confidence < REVIEW_NEEDED_CONFIDENCE_THRESHOLD

    item_attributes[:needs_review] == true
  end

  def item_line?(line)
    return false if line.blank?
    return false if line.include?("合計")
    return false if line.match?(%r{\d{4}[\/-]\d{1,2}[\/-]\d{1,2}})
    return false if line.match?(/現金|cash|visa|master|mastercard|jcb|amex|american express|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakuten pay|d払い|au pay|メルペイ|line pay|デビット|debit/i)

    line.match?(/\S+.*\d+/)
  end

  def extract_item_name(line)
    line.to_s.sub(/\s+\d.*$/, "").strip
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

  def extract_item_line_total(line, price: nil, quantity: nil)
    normalized_price = price || extract_item_price(line)
    normalized_quantity = quantity || extract_item_quantity(line)
    return nil unless normalized_price

    normalized_price * normalized_quantity
  end

  def detect_category(text)
    ReceiptFallbackPatterns.detect_category(text)
  end

  def detect_payment_method(text)
    detected = ReceiptFallbackPatterns.detect_payment_method(text)
    detected == "other" ? nil : detected
  end
end
