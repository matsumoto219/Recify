class Ocr::ResponseParser
  def initialize(response:, provider: nil)
    @response = response
    @provider = provider
  end

  def call
    parsed_response = normalize_response(@response)
    validate_response_shape!(parsed_response)
    raw_text = extract_raw_text(parsed_response)
    normalized_raw_text = normalize_text(raw_text)
    normalized_lines = extract_lines(parsed_response).map { |line| normalize_text(line) }.reject(&:empty?)

    {
      success: normalized_raw_text.present? || normalized_lines.any?,
      raw_text: normalized_raw_text,
      lines: normalized_lines,
      candidates: {
        store_name: extract_store_name(parsed_response, normalized_lines),
        store_address: extract_store_address(parsed_response),                                                     # NOTE: MerchantAddress は取得するが、実レシートで未取得が多く保存/表示は限定的
        store_phone_number: extract_store_phone_number(parsed_response),
        purchased_at_text: normalize_purchased_at_text(extract_purchased_at_text(parsed_response, normalized_lines)),
        total_amount: extract_total_amount(parsed_response, normalized_lines),
        subtotal_amount: extract_subtotal_amount(parsed_response, normalized_lines),
        tax_amount: extract_tax_amount(parsed_response, normalized_lines),
        tax_rate: extract_tax_rate(parsed_response),
        payment_method_text: extract_payment_method_text(parsed_response, normalized_raw_text, normalized_lines),  # NOTE: Payments[].Method が取れない場合の fallback 用。現在はこちらが主力
        tip_amount: extract_tip_amount(parsed_response),                                                           # NOTE: Tip は日本レシートではほぼ存在せず、保存はされるが未使用に近い
        country_region: extract_country_region(parsed_response),
        receipt_type: extract_receipt_type(parsed_response),
        payments: extract_payments(parsed_response),                                                               # NOTE: Payments[] は仕様上保存対象だが未取得ケースが多く、現在はfallbackがメイン
        tax_details: extract_tax_details(parsed_response),                                                         # NOTE: TaxDetails[] は保存対象だがレシート依存で取得率にばらつきあり
        items: extract_items(parsed_response, normalized_lines),                                                   # NOTE: quantity_unit は編集/表示で利用し、product_code は保存する
        confidence_summary: extract_confidence_summary(parsed_response)
      },
      error_code: nil,
      meta: {
        provider: provider,
        model_id: extract_model_id(parsed_response),
        raw_response_included: false
      }
    }
  rescue JSON::ParserError => e
    Rails.logger.error("[OCR::ResponseParser] json_parse_failed class=#{e.class}")
    build_error_result("ocr_api_error")
  rescue InvalidOcrResponseError => e
    Rails.logger.error("[OCR::ResponseParser] invalid_response class=#{e.class} message=#{e.message}")
    build_error_result("ocr_api_error")
  rescue TypeError => e
    Rails.logger.error("[OCR::ResponseParser] type_error class=#{e.class}")
    build_error_result("unexpected_error")
  rescue StandardError => e
    Rails.logger.error("[OCR::ResponseParser] unexpected_error class=#{e.class}")
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
  rescue NoMethodError, TypeError
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

  InvalidOcrResponseError = Class.new(StandardError)

  def extract_analyze_result(parsed_response)
    parsed_response["analyzeResult"] || {}
  end

  def extract_document(parsed_response)
    Array(extract_analyze_result(parsed_response)["documents"]).first || {}
  end

  def validate_response_shape!(parsed_response)
    raise InvalidOcrResponseError, "parsed_response must be a Hash" unless parsed_response.is_a?(Hash)

    analyze_result = parsed_response["analyzeResult"]
    raise InvalidOcrResponseError, "analyzeResult is missing" unless analyze_result.is_a?(Hash)

    documents = analyze_result&.[]("documents")
    if documents.present? && !documents.is_a?(Array)
      raise InvalidOcrResponseError, "documents must be an Array"
    end

    fields = extract_document(parsed_response)["fields"]
    if fields.present? && !fields.is_a?(Hash)
      raise InvalidOcrResponseError, "fields must be a Hash"
    end
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
  # - Discounts / Offers → MVPでは lines から割引額のみ直前itemへ紐付ける
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
    candidates = extract_store_name_candidates(lines, merchant_name)

    candidates.first || merchant_name || lines.find(&:present?)
  end

  def extract_store_name_candidates(lines, merchant_name)
    normalized_lines = Array(lines).filter_map { |line| normalize_store_name_candidate(line) }
    branch_name = extract_branch_like_store_name(normalized_lines, merchant_name)
    brand_name = extract_brand_like_store_name(normalized_lines, branch_name)

    candidates = []
    candidates << combine_brand_and_branch_name(brand_name, branch_name)
    candidates << brand_name
    candidates << branch_name
    candidates << normalize_store_name_candidate(merchant_name)

    candidates.compact_blank.uniq
  end

  def extract_brand_like_store_name(lines, branch_name)
    focused_lines = Array(lines).first(8)
    branch_index = focused_lines.find_index { |line| normalize_store_name_candidate(line) == normalize_store_name_candidate(branch_name) }
    candidate_lines = branch_index ? focused_lines.first(branch_index) : focused_lines

    candidate_lines.find do |line|
      normalized_line = normalize_store_name_candidate(line)
      next false if normalized_line.blank?
      next false if normalized_line == normalize_store_name_candidate(branch_name)
      next false if store_name_noise_line?(normalized_line)
      next false if branch_like_store_name?(normalized_line)

      brand_like_store_name?(normalized_line)
    end
  end

  def brand_like_store_name?(text)
    normalized = normalize_store_name_candidate(text)
    return false if normalized.blank?
    return false if normalized.length < 2
    return false if normalized.length > 40
    return false if normalized.match?(/住所|東京都|道府県|市|区|町|丁目|番地|電話|tel|fax/i)
    return false if normalized.match?(/^[-\d\s.,:;()]+$/)

    normalized.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)
  end

  def combine_brand_and_branch_name(brand_name, branch_name)
    normalized_brand_name = normalize_store_name_candidate(brand_name)
    normalized_branch_name = normalize_store_name_candidate(branch_name)
    return nil if normalized_brand_name.blank? || normalized_branch_name.blank?
    return normalized_brand_name if normalized_brand_name.include?(normalized_branch_name)
    return normalized_branch_name if normalized_branch_name.include?(normalized_brand_name)

    "#{normalized_brand_name} #{normalized_branch_name}"
  end

  def extract_branch_like_store_name(lines, merchant_name)
    normalized_merchant_name = normalize_store_name_candidate(merchant_name)

    Array(lines).find do |line|
      normalized_line = normalize_store_name_candidate(line)
      next false if normalized_line.blank?
      next false if normalized_merchant_name.present? && normalized_line == normalized_merchant_name
      next false if store_name_noise_line?(normalized_line, allow_branch_like: true)

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

  def store_name_noise_line?(text, allow_branch_like: false)
    normalized = normalize_store_name_candidate(text)
    return true if normalized.blank?

    return true if normalized.match?(/tel|fax|領収証|レシート|登録番号|会員|お客様控え|クレジットカード売上票|合計|小計|外税|内税|お釣り|承認番号|取引内容|金額/i)
    return true if normalized.match?(/^\d+[\d\s\/:\-()]*$/)
    return true if normalized.match?(/〒/)
    return true if normalized.match?(/株式会社/)

    return false if allow_branch_like && branch_like_store_name?(normalized)

    normalized.match?(/[0-9]{2,}/)
  end

  # NOTE: Azure側で address 型の場合もあり、valueString/content 以外の対応は今後検討
  def extract_store_address(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("MerchantAddress", "valueString") ||
      fields.dig("MerchantAddress", "content")
  rescue NoMethodError, TypeError
    nil
  end

  def extract_store_phone_number(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("MerchantPhoneNumber", "valuePhoneNumber") ||
      fields.dig("MerchantPhoneNumber", "content") ||
      fields.dig("MerchantPhoneNumber", "valueString")
  rescue NoMethodError, TypeError
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
    line_total_amount = extract_total_amount_from_lines(lines)
    if total_amount.present?
      parsed_total_amount = Amounts::NumberParser.parse_amount(total_amount)
      return line_total_amount if settlement_amount?(parsed_total_amount, lines) && line_total_amount.present?

      return parsed_total_amount
    end

    line_total_amount
  end

  def extract_total_amount_from_lines(lines)
    amount_candidates = Array(lines).filter_map do |line|
      next if settlement_line?(line)
      next unless line.match?(/合計|小計|total|税込|現計/i)

      digits = line.scan(/\d[\d,]*/).map { |value| Amounts::NumberParser.parse_amount(value) }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def settlement_amount?(amount, lines)
    Array(lines).any? do |line|
      settlement_line?(line) &&
        line.scan(/\d[\d,]*/).any? { |value| Amounts::NumberParser.parse_amount(value) == amount }
    end
  end

  def settlement_line?(line)
    line.to_s.match?(/お預かり|お預り|預かり|預り|現金預り|お釣り|釣銭|つり銭|返金/)
  end

  def extract_subtotal_amount(parsed_response, lines)
    fields = extract_fields(parsed_response)

    fields.dig("Subtotal", "valueCurrency", "amount") ||
      fields.dig("Subtotal", "valueNumber") ||
      extract_amount_from_lines(lines, /小計|subtotal|税抜/i)
  rescue NoMethodError, TypeError
    nil
  end

  def extract_tax_amount(parsed_response, lines)
    fields = extract_fields(parsed_response)

    fields.dig("TotalTax", "valueCurrency", "amount") ||
      fields.dig("TotalTax", "valueNumber") ||
      fields.dig("Tax", "valueCurrency", "amount") ||
      fields.dig("Tax", "valueNumber") ||
      extract_amount_from_lines(lines, /消費税|税額|tax/i)
  rescue NoMethodError, TypeError
    nil
  end

  def extract_tax_rate(parsed_response)
    fields = extract_fields(parsed_response)
    details = fields.dig("TaxDetails", "valueArray")
    return nil unless details.is_a?(Array)

    details.filter_map do |detail|
      detail.dig("valueObject", "Rate", "valueNumber")
    end.first
  rescue NoMethodError, TypeError
    nil
  end

  def extract_amount_from_lines(lines, pattern)
    amount_candidates = Array(lines).filter_map do |line|
      next unless line.match?(pattern)

      digits = line.scan(/\d[\d,]*/).map { |value| Amounts::NumberParser.parse_amount(value) }
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

    return "現金" if normalized_lines.any? { |line| cash_total_line?(line) }
    return "商品券" if normalized_lines.any? { |line| voucher_payment_line?(line) }

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

  def cash_total_line?(line)
    normalized = normalize_payment_text(line)
    return false if normalized.blank?

    normalized.match?(/現計|現金計|現金合計/)
  end

  def voucher_payment_line?(line)
    normalized = normalize_payment_text(line)
    return false if normalized.blank?

    normalized.match?(/商品券|金券|ギフト券|お買物券|買物券|voucher|giftcertificate|giftcard|coupon/i)
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
    /現金|cash|商品券|金券|ギフト券|お買物券|買物券|voucher|gift\s*certificate|gift\s*card|coupon|クレジット|credit|visa|mastercard|master|jcb|amex|american\s*express|suica|pasmo|icoca|waon|nanaco|edy|\bid\b|quickpay|quicpay|paypay|楽天ペイ|rakuten\s*pay|d払い|au\s*pay|メルペイ|line\s*pay|デビット|debit/i
  end

  def extract_tip_amount(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("Tip", "valueCurrency", "amount") ||
      fields.dig("Tip", "valueNumber")
  rescue NoMethodError, TypeError
    nil
  end

  def extract_country_region(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("CountryRegion", "valueCountryRegion") ||
      fields.dig("CountryRegion", "valueString")
  rescue NoMethodError, TypeError
    nil
  end

  def extract_receipt_type(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("ReceiptType", "valueString")
  rescue NoMethodError, TypeError
    nil
  end

  # NOTE: 実レシートでは未取得が多く、現在は payment_method_text fallback を優先使用
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
  rescue NoMethodError, TypeError
    []
  end

  # NOTE: 税詳細は取得できる場合のみ保存。現状は UI で未使用
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
  rescue NoMethodError, TypeError
    []
  end

  def extract_items(parsed_response, lines = [])
    fields = extract_fields(parsed_response)
    items = fields.dig("Items", "valueArray")
    return [] unless items.is_a?(Array)

    discount_details_by_index = extract_discount_details_by_item_index(items, lines)

    # NOTE: quantity_unit は編集/表示で利用し、product_code は保存する
    items.map.with_index do |item, index|
      value_object = item["valueObject"] || {}
      total_price = value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber")
      discount_amount = discount_details_by_index.dig(index, :amount).to_i
      original_line_total = discount_details_by_index.dig(index, :original_line_total).presence || total_price
      line_total = if discount_amount.positive?
        [ normalize_amount_for_discount(original_line_total) - discount_amount, 0 ].max
      else
        original_line_total
      end

      {
        raw_text: value_object.dig("Description", "valueString") ||
          value_object.dig("Description", "content") ||
          item["content"],
        price: value_object.dig("Price", "valueCurrency", "amount") || value_object.dig("Price", "valueNumber"),
        quantity: value_object.dig("Quantity", "valueNumber"),
        quantity_unit: value_object.dig("QuantityUnit", "valueString"),
        product_code: value_object.dig("ProductCode", "valueString"),
        line_total: line_total,
        original_line_total: original_line_total,
        discount_amount: discount_amount.positive? ? discount_amount : nil,
        discount_rate: discount_details_by_index.dig(index, :rate),
        confidence: item["confidence"]
      }
    end
  rescue NoMethodError, TypeError
    []
  end

  # NOTE: 割引検出。
  # lines上で item名 → 金額 → 割引 → 割引率 → 割引額 の順に並ぶケースを対象に、
  # 割引額・割引率・割引前金額を直前itemへ紐付ける。
  def extract_discount_details_by_item_index(items, lines)
    normalized_lines = Array(lines).map { |line| normalize_text(line) }
    return {} if normalized_lines.blank?

    item_labels = items.map do |item|
      value_object = item["valueObject"] || {}
      normalize_text(
        value_object.dig("Description", "valueString") ||
          value_object.dig("Description", "content") ||
          item["content"]
      )
    end

    item_original_totals = items.map do |item|
      value_object = item["valueObject"] || {}
      value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber")
    end

    current_item_index = nil
    next_item_index = 0
    waiting_discount = false
    current_discount_rate = nil
    discount_details_by_index = Hash.new { |hash, key| hash[key] = { amount: 0, rate: nil, original_line_total: nil } }

    normalized_lines.each do |line|
      matched_item_index = match_item_index_from_line(line, item_labels, next_item_index)
      if matched_item_index
        current_item_index = matched_item_index
        next_item_index = matched_item_index + 1
        waiting_discount = false
        current_discount_rate = nil
        next
      end

      if discount_keyword_line?(line)
        waiting_discount = current_item_index.present?
        current_discount_rate = nil
        next
      end

      next unless waiting_discount

      extracted_rate = extract_discount_rate_from_line(line)
      if extracted_rate
        current_discount_rate = extracted_rate
        next
      end

      discount_amount = extract_discount_amount_from_line(line)
      next unless discount_amount.positive?

      original_line_total = normalize_amount_for_discount(item_original_totals[current_item_index])
      detail = discount_details_by_index[current_item_index]
      detail[:amount] += discount_amount
      detail[:rate] ||= current_discount_rate
      detail[:original_line_total] ||= original_line_total if original_line_total.positive?

      waiting_discount = false
      current_discount_rate = nil
    end

    discount_details_by_index
  end

  def match_item_index_from_line(line, item_labels, start_index)
    item_labels.each_with_index.drop(start_index).find do |label, _index|
      next false if label.blank?

      line.include?(label) || label.include?(line)
    end&.last
  end

  def discount_keyword_line?(line)
    line.match?(/割引|値引|discount|off/i)
  end

  def extract_discount_rate_from_line(line)
    return nil if line.match?(/[-−▲]/)

    matched = line.match(/(\d+(?:\.\d+)?)\s*%/)
    return nil unless matched

    BigDecimal(matched[1]) / 100
  end

  def extract_discount_amount_from_line(line)
    return 0 unless line.match?(/[-−▲]/)

    line.scan(/\d[\d,]*/).map { |value| Amounts::NumberParser.parse_amount(value) }.max.to_i
  end

  def normalize_amount_for_discount(value)
    Amounts::NumberParser.parse_amount(value)
  end

  def build_error_result(error_code)
    Ocr::ResultTemplate.error_result(
      error_code: error_code,
      provider: provider,
      model_id: nil
    )
  end
end
