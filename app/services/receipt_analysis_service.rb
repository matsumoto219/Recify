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

class Ocr::ResponseParser
  def initialize(response:, provider: nil)
    @response = response
    @provider = provider
  end

  def call
    parsed_response = normalize_response(@response)
    raw_text = extract_raw_text(parsed_response)
    normalized_raw_text = normalize_text(raw_text)
    normalized_lines = extract_lines(parsed_response).map { |line| normalize_text(line) }.reject(&:empty?)

    {
      success: normalized_raw_text.present? || normalized_lines.any?,
      raw_text: normalized_raw_text,
      lines: normalized_lines,
      candidates: {
        store_name: extract_store_name(parsed_response, normalized_lines),
        store_address: extract_store_address(parsed_response),
        store_phone_number: extract_store_phone_number(parsed_response),
        purchased_at_text: normalize_purchased_at_text(extract_purchased_at_text(parsed_response, normalized_lines)),
        total_amount: extract_total_amount(parsed_response, normalized_lines),
        subtotal_amount: extract_subtotal_amount(parsed_response, normalized_lines),
        tax_amount: extract_tax_amount(parsed_response, normalized_lines),
        tax_rate: extract_tax_rate(parsed_response),
        payment_method_text: extract_payment_method_text(parsed_response, normalized_raw_text, normalized_lines),
        tip_amount: extract_tip_amount(parsed_response),
        country_region: extract_country_region(parsed_response),
        receipt_type: extract_receipt_type(parsed_response),
        payments: extract_payments(parsed_response),
        tax_details: extract_tax_details(parsed_response),
        items: extract_items(parsed_response),
        confidence_summary: extract_confidence_summary(parsed_response)
      },
      error_code: nil,
      meta: {
        provider: @provider,
        model_id: extract_model_id(parsed_response),
        raw_response_included: false
      }
    }
  rescue JSON::ParserError
    build_error_result("ocr_api_error")
  rescue TypeError
    build_error_result("unexpected_error")
  rescue StandardError
    build_error_result("unexpected_error")
  end

  def extract_confidence_summary(parsed_response)
    fields = extract_fields(parsed_response)
    items = fields.dig("Items", "valueArray")
    item_confidences = Array(items).filter_map { |item| item["confidence"]&.to_f }

    {
      merchant_name: fields.dig("MerchantName", "confidence"),
      purchased_at: fields.dig("TransactionDate", "confidence"),
      total_amount: fields.dig("Total", "confidence"),
      subtotal_amount: fields.dig("Subtotal", "confidence"),
      tax_amount: fields.dig("TotalTax", "confidence") || fields.dig("Tax", "confidence"),
      tax_rate: Array(fields.dig("TaxDetails", "valueArray")).filter_map { |detail| detail.dig("valueObject", "Rate", "confidence") }.first,
      items_average: item_confidences.any? ? (item_confidences.sum / item_confidences.size.to_f).round(4) : nil,
      overall: extract_document(parsed_response)["confidence"]
    }
  rescue
    {
      merchant_name: nil,
      purchased_at: nil,
      total_amount: nil,
      subtotal_amount: nil,
      tax_amount: nil,
      tax_rate: nil,
      items_average: nil,
      overall: nil
    }
  end

  private

  attr_reader :response, :provider

  def extract_analyze_result(parsed_response)
    parsed_response["analyzeResult"] || {}
  end

  def extract_document(parsed_response)
    Array(extract_analyze_result(parsed_response)["documents"]).first || {}
  end

  # NOTE: 以下はAzure OCR (Document Intelligence) のレスポンスで取得可能だが、
  # 現在のRecifyでは未使用 or 未マッピングのフィールド一覧
  # 必要に応じて今後対応検討する
  #
  # - MerchantAddress (住所) → 現状は未取得 or 不安定
  # - Tip (チップ) → 日本レシートではほぼ未使用
  # - Payments (構造化支払い情報) → 未取得ケースが多く fallback運用
  # - Loyalty / Membership系 → ポイントカード誤認のため未採用
  # - ReceiptId / TransactionId → 今回のスコープ外
  # - CurrencyCode → JPY固定前提のため未使用
  # - Discounts / Offers → item.contentに含まれるが未分離
  # - ProductCode → レシートによっては存在するが未活用
  # - AdditionalFields (query fields拡張分) → PaymentMethod以外は未使用
  #
  # 方針:
  # - parserでは「安全に取れるものだけ扱う」
  # - 不安定なフィールドは後段（AI or Service層）で扱う
  def extract_fields(parsed_response)
    extract_document(parsed_response)["fields"] || parsed_response["fields"] || {}
  end

  def extract_model_id(parsed_response)
    extract_analyze_result(parsed_response)["modelId"]
  end

  def normalize_response(value)
    case value
    when String
      JSON.parse(value)
    when Hash
      value.deep_stringify_keys
    else
      raise TypeError, "unsupported ocr response"
    end
  end

  def extract_raw_text(parsed_response)
    parsed_response["raw_text"] ||
      extract_analyze_result(parsed_response)["content"] ||
      parsed_response.dig("text") ||
      parsed_response.dig("full_text") ||
      parsed_response.dig("result", "text") ||
      extract_lines(parsed_response).join("\n")
  end

  def extract_lines(parsed_response)
    azure_lines = Array(extract_analyze_result(parsed_response)["pages"]).flat_map do |page|
      Array(page["lines"]).filter_map { |line| line["content"] }
    end
    return azure_lines if azure_lines.any?

    explicit_lines = parsed_response["lines"] || parsed_response.dig("result", "lines")
    return explicit_lines if explicit_lines.is_a?(Array)

    raw_text = parsed_response["raw_text"] ||
      extract_analyze_result(parsed_response)["content"] ||
      parsed_response["text"] ||
      parsed_response["full_text"]
    return [] if raw_text.blank?

    raw_text.to_s.lines.map(&:chomp)
  end

  def normalize_text(text)
    text.to_s
      .unicode_normalize(:nfkc)
      .downcase
      .gsub(/[[:space:]]+/, " ")
      .strip
  end

  def extract_store_name(parsed_response, lines)
    fields = extract_fields(parsed_response)
    merchant_name = fields.dig("MerchantName", "valueString") || fields.dig("MerchantName", "content")
    branch_name = extract_branch_like_store_name(lines, merchant_name)

    branch_name || merchant_name || lines.find(&:present?)
  end

  def extract_branch_like_store_name(lines, merchant_name)
    normalized_merchant_name = normalize_store_name_candidate(merchant_name)

    Array(lines).find do |line|
      normalized_line = normalize_store_name_candidate(line)
      next false if normalized_line.blank?
      next false if normalized_merchant_name.present? && normalized_line == normalized_merchant_name
      next false if store_name_noise_line?(normalized_line)

      branch_like_store_name?(normalized_line)
    end
  end

  def normalize_store_name_candidate(text)
    return nil if text.blank?

    text.to_s.unicode_normalize(:nfkc).strip.presence
  end

  def branch_like_store_name?(text)
    normalized = normalize_store_name_candidate(text)
    return false if normalized.blank?

    return true if normalized.match?(/店$/)
    return true if normalized.match?(/支店|本店|営業所|センター|モール|ショップ|market|mart|store/i)

    false
  end

  def store_name_noise_line?(text)
    normalized = normalize_store_name_candidate(text)
    return true if normalized.blank?

    noise_patterns = [
      /tel|fax|領収証|レシート|登録番号|会員|お客様控え|クレジットカード売上票|合計|小計|外税|内税|お釣り|承認番号|取引内容|金額/i,
      /^\d+[\d\s\/:\-()]*$/,
      /〒/,
      /株式会社/,
      /[0-9]{2,}/
    ]

    noise_patterns.any? { |pattern| normalized.match?(pattern) }
  end

  def extract_store_address(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("MerchantAddress", "valueString") ||
      fields.dig("MerchantAddress", "content")
  rescue
    nil
  end

  def extract_store_phone_number(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("MerchantPhoneNumber", "valuePhoneNumber") ||
      fields.dig("MerchantPhoneNumber", "content") ||
      fields.dig("MerchantPhoneNumber", "valueString")
  rescue
    nil
  end

  def extract_purchased_at_text(parsed_response, lines)
    fields = extract_fields(parsed_response)
    date = fields.dig("TransactionDate", "valueDate")
    time = fields.dig("TransactionTime", "valueTime")
    return [ date, time ].compact.join(" ") if date.present? || time.present?

    lines.find do |line|
      line.match?(/\d{4}[\/\-年]\d{1,2}[\/\-月]\d{1,2}日?(\s+\d{1,2}:\d{2})?/) ||
        line.match?(/\d{1,2}[\/\-]\d{1,2}[\/\-]\d{1,2,4}(\s+\d{1,2}:\d{2})?/) ||
        line.match?(/\d{1,2}:\d{2}/)
    end
  end

  def normalize_purchased_at_text(text)
    return nil if text.blank?

    text.to_s.gsub("/", "-")
  end

  def extract_total_amount(parsed_response, lines)
    fields = extract_fields(parsed_response)
    total_amount = fields.dig("Total", "valueCurrency", "amount") || fields.dig("Total", "valueNumber")
    return total_amount.to_i if total_amount.present?

    amount_candidates = lines.filter_map do |line|
      next unless line.match?(/合計|total|税込|現計/i)

      digits = line.scan(/\d[\d,]*/).map { |value| value.delete(",\n").to_i }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def extract_subtotal_amount(parsed_response, lines)
    fields = extract_fields(parsed_response)

    fields.dig("Subtotal", "valueCurrency", "amount") ||
      fields.dig("Subtotal", "valueNumber") ||
      extract_amount_from_lines(lines, /小計|subtotal|税抜/i)
  rescue
    nil
  end

  def extract_tax_amount(parsed_response, lines)
    fields = extract_fields(parsed_response)

    fields.dig("TotalTax", "valueCurrency", "amount") ||
      fields.dig("TotalTax", "valueNumber") ||
      fields.dig("Tax", "valueCurrency", "amount") ||
      fields.dig("Tax", "valueNumber") ||
      extract_amount_from_lines(lines, /消費税|税額|tax/i)
  rescue
    nil
  end

  def extract_tax_rate(parsed_response)
    fields = extract_fields(parsed_response)
    details = fields.dig("TaxDetails", "valueArray")
    return nil unless details.is_a?(Array)

    details.filter_map do |detail|
      detail.dig("valueObject", "Rate", "valueNumber")
    end.first
  rescue
    nil
  end

  def extract_amount_from_lines(lines, pattern)
    amount_candidates = Array(lines).filter_map do |line|
      next unless line.match?(pattern)

      digits = line.scan(/\d[\d,]*/).map { |value| value.delete(",\n").to_i }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def extract_payment_method_text(parsed_response, raw_text, lines)
    fields = extract_fields(parsed_response)
    query_field_names = %w[PaymentMethod PaymentsMethod]

    query_field_names.each do |field_name|
      value = fields.dig(field_name, "valueString") || fields.dig(field_name, "content")
      normalized_value = normalize_payment_text(value)
      return normalized_value if normalized_value.present? && !point_or_membership_only_text?(normalized_value)
    end

    strong_line = extract_payment_method_from_lines(lines)
    return strong_line if strong_line.present?

    normalized_raw_match = normalize_payment_text(raw_text.to_s.match(payment_method_pattern)&.[](0))
    return normalized_raw_match if normalized_raw_match.present? && !point_or_membership_only_text?(normalized_raw_match)

    nil
  end

  def extract_payment_method_from_lines(lines)
    normalized_lines = Array(lines).map { |line| normalize_payment_text(line) }.compact

    card_slip_index = normalized_lines.find_index do |line|
      line.match?(/クレジットカード売上票|カード会社|お支払方法|支払方法|payment method/i)
    end

    if card_slip_index
      focused_lines = normalized_lines[[ card_slip_index - 2, 0 ].max..[ card_slip_index + 5, normalized_lines.length - 1 ].min]
      focused_match = focused_lines.find do |line|
        next false if point_or_membership_only_text?(line)

        line.match?(payment_method_pattern)
      end
      return focused_match.match(payment_method_pattern)&.[](0) if focused_match.present?
    end

    payment_line = normalized_lines.find do |line|
      next false if point_or_membership_only_text?(line)

      line.match?(/支払|決済|payment/i) && line.match?(payment_method_pattern)
    end
    return payment_line.match(payment_method_pattern)&.[](0) if payment_line.present?

    general_match = normalized_lines.find do |line|
      next false if point_or_membership_only_text?(line)

      line.match?(payment_method_pattern)
    end
    general_match.match(payment_method_pattern)&.[](0) if general_match.present?
  end

  def normalize_payment_text(text)
    return nil if text.blank?

    text.to_s.gsub(/[[:space:]]+/, "").presence
  end

  def point_or_membership_only_text?(text)
    normalized = normalize_payment_text(text)
    return false if normalized.blank?

    point_keywords = /ポイント|point|会員|member|楽天ポイント|楽天ポイン|waonpoint|tポイント|dポイント|ponta/i
    payment_keywords = /現金|cash|クレジット|credit|visa|mastercard|master|jcb|amex|americanexpress|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakutenpay|d払い|aupay|メルペイ|linepay|デビット|debit|カード|支払|決済/i

    normalized.match?(point_keywords) && !normalized.match?(payment_keywords)
  end

  def payment_method_pattern
    /現金|cash|クレジット|credit|visa|mastercard|master|jcb|amex|american\s*express|suica|pasmo|icoca|waon|nanaco|edy|\bid\b|quickpay|quicpay|paypay|楽天ペイ|rakuten\s*pay|d払い|au\s*pay|メルペイ|line\s*pay|デビット|debit/i
  end

  def extract_tip_amount(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("Tip", "valueCurrency", "amount") ||
      fields.dig("Tip", "valueNumber")
  rescue
    nil
  end

  def extract_country_region(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("CountryRegion", "valueCountryRegion") ||
      fields.dig("CountryRegion", "valueString")
  rescue
    nil
  end

  def extract_receipt_type(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("ReceiptType", "valueString")
  rescue
    nil
  end

  def extract_payments(parsed_response)
    fields = extract_fields(parsed_response)
    payments = fields.dig("Payments", "valueArray")
    return [] unless payments.is_a?(Array)

    payments.map do |payment|
      value_object = payment["valueObject"] || {}

      {
        method: value_object.dig("Method", "valueString") || value_object.dig("Method", "content"),
        amount: value_object.dig("Amount", "valueCurrency", "amount") || value_object.dig("Amount", "valueNumber")
      }
    end
  rescue
    []
  end

  def extract_tax_details(parsed_response)
    fields = extract_fields(parsed_response)
    details = fields.dig("TaxDetails", "valueArray")
    return [] unless details.is_a?(Array)

    details.map do |detail|
      value_object = detail["valueObject"] || {}
      {
        description: value_object.dig("Description", "valueString") || value_object.dig("Description", "content"),
        amount: value_object.dig("Amount", "valueCurrency", "amount") || value_object.dig("Amount", "valueNumber"),
        rate: value_object.dig("Rate", "valueNumber"),
        net_amount: value_object.dig("NetAmount", "valueCurrency", "amount") || value_object.dig("NetAmount", "valueNumber")
      }
    end
  rescue
    []
  end

  def extract_items(parsed_response)
    fields = extract_fields(parsed_response)
    items = fields.dig("Items", "valueArray")
    return [] unless items.is_a?(Array)

    items.map do |item|
      value_object = item["valueObject"] || {}

      {
        raw_text: value_object.dig("Description", "valueString") ||
          value_object.dig("Description", "content") ||
          item["content"],
        price: value_object.dig("Price", "valueCurrency", "amount") || value_object.dig("Price", "valueNumber"),
        quantity: value_object.dig("Quantity", "valueNumber"),
        quantity_unit: value_object.dig("QuantityUnit", "valueString"),
        product_code: value_object.dig("ProductCode", "valueString"),
        line_total: value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber"),
        confidence: item["confidence"]
      }
    end
  rescue
    []
  end

  def build_error_result(error_code)
    {
      success: false,
      raw_text: "",
      lines: [],
      candidates: {
        store_name: nil,
        store_address: nil,
        store_phone_number: nil,
        purchased_at_text: nil,
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil,
        payment_method_text: nil,
        tip_amount: nil,
        country_region: nil,
        receipt_type: nil,
        payments: [],
        tax_details: [],
        items: [],
        confidence_summary: {
          merchant_name: nil,
          purchased_at: nil,
          total_amount: nil,
          subtotal_amount: nil,
          tax_amount: nil,
          tax_rate: nil,
          items_average: nil,
          overall: nil
        }
      },
      error_code: error_code,
      meta: {
        provider: @provider,
        model_id: nil,
        raw_response_included: false
      }
    }
  end
end
