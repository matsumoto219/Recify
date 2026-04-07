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
