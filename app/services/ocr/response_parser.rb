class Ocr::ResponseParser
  PAYMENT_METHOD_PATTERN = /現金|cash|商品券|金券|ギフト券|お買物券|買物券|voucher|gift\s*certificate|gift\s*card|coupon|クレジット|credit|visa|mastercard|mastercard|master|jcb|amex|american\s*express|diners|discover|unionpay|union\s*pay|銀聯|suica|pasmo|icoca|交通系ic|交通系電子マネー|電子マネー|waon|nanaco|楽天edy|edy|\bid\b|quickpay|quicpay|contactless|タッチ決済|コンタクトレス|\bnfc\b|mobilepayment|applepay|googlepay|paypay|楽天ペイ|rakuten\s*pay|d払い|dpayment|au\s*pay|aupay|メルペイ|line\s*pay|linepay|alipay|wechatpay|デビット|debit/i.freeze
  POINT_KEYWORDS_PATTERN = /ポイント|point|会員|member|楽天ポイント|楽天ポイン|waonpoint|tポイント|dポイント|ponta/i.freeze
  PAYMENT_KEYWORDS_PATTERN = /現金|cash|クレジット|credit|visa|mastercard|master|jcb|amex|americanexpress|diners|discover|unionpay|銀聯|suica|pasmo|icoca|交通系ic|交通系電子マネー|電子マネー|waon|nanaco|edy|id|quickpay|quicpay|contactless|タッチ決済|コンタクトレス|nfc|mobilepayment|applepay|googlepay|paypay|楽天ペイ|rakutenpay|d払い|dpayment|aupay|メルペイ|linepay|alipay|wechatpay|デビット|debit|カード|支払|決済/i.freeze
  PAYMENT_SUPPORT_ONLY_PATTERN = /対応|使えます|使える|利用可|ご利用(?:いただけます|できます|可能)|取扱|取り扱|accepted|available|supported|weaccept/i.freeze
  PAYMENT_TRANSACTION_CONTEXT_PATTERN = /支払|お支払|支払い|決済|会計|精算|売上|利用額|支払額|payment|paid|tender|settlement|charge/i.freeze
  CASH_TOTAL_PATTERN = /現計|現金計|現金合計/.freeze
  VOUCHER_PAYMENT_PATTERN = /商品券|金券|ギフト券|お買物券|買物券|voucher|giftcertificate|giftcard|coupon/i.freeze
  SETTLEMENT_LINE_PATTERN = /お預かり|お預り|預かり|預り|現金預り|お釣り|釣銭|つり銭|返金/.freeze
  MULTIPLE_RECEIPTS_REVIEW_REASON = "multiple_receipts_suspected"
  MULTIPLE_RECEIPTS_MIN_LINES = 8
  MULTIPLE_RECEIPTS_MIN_CLUSTER_RATIO = 0.2
  MULTIPLE_RECEIPTS_HORIZONTAL_GAP_RATIO = 0.08
  MULTIPLE_RECEIPTS_VERTICAL_GAP_RATIO = 0.1
  MULTIPLE_RECEIPTS_MIN_ANCHOR_LINES = 4
  MULTIPLE_RECEIPTS_MIN_ANCHOR_CATEGORIES = 4
  ADJUSTMENT_MONEY_PATTERN = /[▲△\-−]?\s*[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?/.freeze
  ADJUSTMENT_SIGNED_MONEY_PATTERN = /(?:\A|[\s　])(?:[▲△]|[\-−]\s*)[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?/.freeze
  ADJUSTMENT_AMOUNT_ONLY_PATTERN = /\A\s*[▲△\-−]?\s*[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?\s*\z/.freeze
  ADJUSTMENT_DISCOUNT_LABEL_PATTERN = /返品|返金|取消|キャンセル|値引|割引|クーポン|coupon|discount|refund|return/i.freeze
  ADJUSTMENT_SURCHARGE_LABEL_PATTERN = /深夜|サービス料|配送料|送料|レジ袋|袋代|手数料|チャージ|fee|charge|surcharge|delivery|shipping|bag|handling/i.freeze
  ADJUSTMENT_EXCLUDED_LINE_PATTERN = /小計|商品小計|合計|総合計|税抜合計|税込合計|対象|消費税|税額|税率|内税|外税|お預かり|お預り|預り|釣銭|お釣り|つり銭|支払|お支払|決済|現金|カード|au\s*pay|paypay|楽天ペイ|ポイント|獲得|利用可能|残高|カード番号|取引番号|レシート|領収|tel|電話|住所|登録番号|返品はお受け|返品.*(?:不可|致しかね)|お受け致しかね|barcode|qr|total|subtotal|tax|payment|change|point/i.freeze
  ADJUSTMENT_ZONE_START_PATTERN = /小計|商品小計|税抜合計|内税品計|subtotal/i.freeze
  ADJUSTMENT_ZONE_END_PATTERN = /合計|総合計|total/i.freeze
  MERCHANT_ANCHOR_PATTERN = /店舗|店名|店|マーケット|スーパー|株式会社|有限会社|住所|所在地|電話|tel|market|store|mart|shop/i.freeze
  DATETIME_ANCHOR_PATTERN = /(?:\d{4}[\/\-年]\s*\d{1,2}[\/\-月]\s*\d{1,2}日?)|(?:\d{1,2}[:：]\d{2})/.freeze
  SUBTOTAL_ANCHOR_PATTERN = /小\s*計|subtotal/i.freeze
  TOTAL_ANCHOR_PATTERN = /合\s*計|総合計|total/i.freeze
  TAX_ANCHOR_PATTERN = /消費税|税額|税率|税込|税抜|外税|内税|tax/i.freeze
  PAYMENT_ANCHOR_PATTERN = /支払|お支払|決済|現金|クレジット|visa|master|jcb|預り|お預り|釣|お釣り|釣銭|pay/i.freeze
  PAYMENT_QUERY_FIELD_NAME = "PaymentMethods"
  GENERIC_TAX_DETAIL_DESCRIPTION_PATTERN = /\A(?:内)?消費税等?\z|\A税額\z|\Atax\z/i.freeze
  POLLING_METRICS_KEY = Ocr::Client::POLLING_METRICS_KEY
  POLLING_METRIC_KEYS = %i[
    elapsed_ms
    poll_count
    final_status
    max_poll_count
    poll_interval
    total_poll_sleep_ms
    max_poll_interval
    poll_backoff_factor
    reached_max_poll
    retry_after_used
    retry_count
  ].freeze

  def initialize(response:, provider: nil)
    @response = response
    @provider = provider
  end

  def call
    reset_cached_response_state!
    parsed_response = (@parsed_response = normalize_response(@response))
    validate_response_shape!(parsed_response)
    raw_text = extract_raw_text(parsed_response)
    normalized_raw_text = normalize_text(raw_text)
    normalized_lines = normalized_lines(parsed_response)

    {
      success: normalized_raw_text.present? || normalized_lines.any?,
      raw_text: normalized_raw_text,
      lines: normalized_lines,
      candidates: {
        store_name: extract_store_name(parsed_response, normalized_lines),
        store_address: extract_store_address(parsed_response),                                                     # MerchantAddress は取得率にばらつきあり。取得値は住所として保存/表示する
        store_address_components: extract_store_address_components(parsed_response),
        store_phone_number: extract_store_phone_number(parsed_response),
        purchased_at_text: normalize_purchased_at_text(extract_purchased_at_text(parsed_response, normalized_lines)),
        total_amount: extract_total_amount(parsed_response, normalized_lines),
        subtotal_amount: extract_subtotal_amount(parsed_response, normalized_lines),
        tax_amount: extract_tax_amount(parsed_response, normalized_lines),
        tax_rate: extract_tax_rate(parsed_response),
        payment_method_text: extract_payment_method_text(parsed_response, normalized_raw_text, normalized_lines),
        payment_candidates: extract_payment_candidates(parsed_response),
        tip_amount: extract_tip_amount(parsed_response),                                                           # NOTE: Tip は日本レシートではほぼ存在せず、保存はされるが未使用に近い
        currency_code: extract_currency_code(parsed_response),
        country_region: extract_country_region(parsed_response),
        receipt_type: extract_receipt_type(parsed_response),
        payments: extract_payments(parsed_response),                                                               # NOTE: Payments[] は仕様上保存対象だが未取得ケースが多く、現在はfallbackがメイン
        tax_details: extract_tax_details(parsed_response, normalized_lines),
        adjustment_candidates: extract_adjustment_candidates(parsed_response, normalized_lines),
        items: extract_items(parsed_response, normalized_lines),
        review_reasons: extract_review_reasons(parsed_response),
        confidence_summary: extract_confidence_summary(parsed_response)
      },
      error_code: nil,
      meta: {
        provider: provider,
        model_id: extract_model_id(parsed_response),
        doc_type: extract_doc_type(parsed_response),
        polling_metrics: extract_polling_metrics(parsed_response),
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
    return @analyze_result if cacheable_response?(parsed_response) && defined?(@analyze_result)

    result = parsed_response["analyzeResult"] || {}
    @analyze_result = result if cacheable_response?(parsed_response)
    result
  end

  def extract_document(parsed_response)
    return @document if cacheable_response?(parsed_response) && defined?(@document)

    document = Array(extract_analyze_result(parsed_response)["documents"]).first || {}
    @document = document if cacheable_response?(parsed_response)
    document
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

  # Azure OCR (Document Intelligence) のレスポンスで取得可能だが、
  # 現在のRecifyでは未表示/限定利用、または意図的に対象外としているフィールドメモ。
  # 取得率や実レシートでの有用性を見ながら、必要に応じて対応を広げる。
  #
  # - Tip (チップ) → 保存済み。日本レシートではほぼ未使用
  # - Payments (構造化支払い情報) → 保存済み。未取得ケースが多く fallback運用
  # - MerchantAddress.content/valueString → store_address、valueAddress → store_address_componentsへ保存済み
  # - valueCurrency.currencyCode → receipts.currency_codeへ代表通貨として保存済み。金額計算は現状JPY前提を維持
  # - Loyalty / Membership系 → ポイントカード誤認のため未採用
  # - ReceiptId / TransactionId → 今回のスコープ外
  # - Discounts / Offers → MVPでは lines から割引額のみ直前itemへ紐付ける
  # - ProductCode → 保存のみで、画面表示/検索では未使用
  # - Hotel専用field / MerchantAliases / Items.Date / Items.Category → 通常レシート対象外のため未採用
  # - PaymentMethods query field → 公式schemaの Payments[] とは別のqueryFields補助候補。
  #   DB保存や payment_method_text 昇格はせず、AI判断材料として payment_candidates に渡す
  #
  # 方針:
  # - parserでは「安全に取れるものだけ扱う」
  # - 不安定なフィールドは後段（AI or Service層）で扱う
  def extract_fields(parsed_response)
    return @fields if cacheable_response?(parsed_response) && defined?(@fields)

    fields = extract_document(parsed_response)["fields"] || parsed_response["fields"] || {}
    @fields = fields if cacheable_response?(parsed_response)
    fields
  end

  def extract_model_id(parsed_response)
    extract_analyze_result(parsed_response)["modelId"]
  end

  def extract_doc_type(parsed_response)
    extract_document(parsed_response)["docType"]
  end

  def extract_polling_metrics(parsed_response)
    metrics = polling_metrics_hash(parsed_response[POLLING_METRICS_KEY])
    return {} if metrics.blank?

    POLLING_METRIC_KEYS.each_with_object({}) do |key, memo|
      value = metrics[key]
      memo[key] = normalize_polling_metric_value(key, value) unless value.nil?
    end.compact
  end

  def normalize_polling_metric_value(key, value)
    case key
    when :elapsed_ms, :poll_count, :max_poll_count, :total_poll_sleep_ms, :retry_count
      Integer(value, exception: false)
    when :poll_interval, :max_poll_interval, :poll_backoff_factor
      Float(value, exception: false)
    when :reached_max_poll, :retry_after_used
      ActiveModel::Type::Boolean.new.cast(value)
    else
      value.to_s.presence
    end
  end

  def polling_metrics_hash(value)
    return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

    {}.with_indifferent_access
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
    return @raw_lines if cacheable_response?(parsed_response) && defined?(@raw_lines)

    azure_lines = Array(extract_analyze_result(parsed_response)["pages"]).flat_map do |page|
      Array(page["lines"]).filter_map { |line| line["content"] }
    end
    return cache_lines(parsed_response, azure_lines) if azure_lines.any?

    explicit_lines = parsed_response["lines"] || parsed_response.dig("result", "lines")
    return cache_lines(parsed_response, explicit_lines) if explicit_lines.is_a?(Array)

    raw_text = parsed_response["raw_text"] ||
      extract_analyze_result(parsed_response)["content"] ||
      parsed_response["text"] ||
      parsed_response["full_text"]
    return cache_lines(parsed_response, []) if raw_text.blank?

    cache_lines(parsed_response, raw_text.to_s.lines.map(&:chomp))
  end

  def normalized_lines(parsed_response)
    return @normalized_lines if cacheable_response?(parsed_response) && defined?(@normalized_lines)

    lines = extract_lines(parsed_response).map { |line| normalize_text(line) }.reject(&:empty?)
    @normalized_lines = lines if cacheable_response?(parsed_response)
    lines
  end

  def normalize_text(text)
    @normalized_texts ||= {}
    key = text_cache_key(text)
    @normalized_texts[key] ||= key
      .unicode_normalize(:nfkc)
      .downcase
      .gsub(/[[:space:]]+/, " ")
      .strip
      .freeze
  end

  def extract_store_name(parsed_response, lines)
    fields = extract_fields(parsed_response)
    merchant_name = fields.dig("MerchantName", "valueString") || fields.dig("MerchantName", "content")
    candidates = extract_store_name_candidates(lines, merchant_name)

    candidates.first || merchant_name || lines.find(&:present?)
  end

  def extract_store_name_candidates(lines, merchant_name)
    normalized_lines = Array(lines).filter_map { |line| normalize_store_name_candidate(line) }
    normalized_merchant_name = normalize_store_name_candidate(merchant_name)
    heading_candidates = Analysis::StoreNameCandidateClassifier.customer_facing_heading_candidates(normalized_lines)
    operator_merchant_name = Analysis::StoreNameCandidateClassifier.operator_legal_entity_candidate?(
      normalized_merchant_name,
      normalized_lines
    )
    branch_name = extract_branch_like_store_name(normalized_lines, merchant_name)
    if branch_like_store_name?(normalized_merchant_name) &&
        !Analysis::StoreNameCandidateClassifier.legal_entity_name?(normalized_merchant_name)
      branch_name ||= normalized_merchant_name
    end
    brand_name = extract_brand_like_store_name(normalized_lines, branch_name)

    candidates = []
    candidates.concat(heading_candidates) if operator_merchant_name
    candidates << combine_brand_and_branch_name(brand_name, branch_name)
    candidates << normalized_merchant_name if normalized_merchant_name.present? && branch_name.blank? && !operator_merchant_name
    candidates << brand_name
    candidates << branch_name
    candidates << normalized_merchant_name
    candidates.concat(heading_candidates) unless operator_merchant_name

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
      next false if normalized_merchant_name.present? && normalized_line.casecmp?(normalized_merchant_name)
      next false if store_name_noise_line?(normalized_line, allow_branch_like: true)

      branch_like_store_name?(normalized_line)
    end
  end

  def normalize_store_name_candidate(text)
    return nil if text.blank?

    @normalized_store_name_candidates ||= {}
    key = text_cache_key(text)
    @normalized_store_name_candidates[key] ||= key.unicode_normalize(:nfkc).strip.presence&.freeze
  end

  def branch_like_store_name?(text)
    normalized = normalize_store_name_candidate(text)
    return false if normalized.blank?

    return true if normalized.match?(/店$/)
    return true if normalized.match?(/支店|本店|営業所|センター|モール|ショップ|market|mart|store/i)
    return true if normalized.match?(/通り|駅前|南口|北口|東口|西口/)

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

  # 表示/編集用の住所文字列。MerchantAddress.valueAddress は store_address_components として別保存する。
  def extract_store_address(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("MerchantAddress", "valueString") ||
      fields.dig("MerchantAddress", "content")
  rescue NoMethodError, TypeError
    nil
  end

  def extract_store_address_components(parsed_response)
    fields = extract_fields(parsed_response)
    value_address = fields.dig("MerchantAddress", "valueAddress")
    return {} unless value_address.is_a?(Hash)

    value_address.deep_stringify_keys
  rescue NoMethodError, TypeError
    {}
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
      parsed_total_amount = ReceiptAmountService.parse_amount(total_amount)
      return line_total_amount if settlement_amount?(parsed_total_amount, lines) && line_total_amount.present?

      return parsed_total_amount
    end

    line_total_amount
  end

  def extract_total_amount_from_lines(lines)
    amount_candidates = Array(lines).filter_map do |line|
      next if settlement_line?(line)
      next unless line.match?(/合計|小計|total|税込|現計/i)

      digits = line.scan(/\d[\d,]*/).map { |value| ReceiptAmountService.parse_amount(value) }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def settlement_amount?(amount, lines)
    Array(lines).any? do |line|
      settlement_line?(line) &&
        line.scan(/\d[\d,]*/).any? { |value| ReceiptAmountService.parse_amount(value) == amount }
    end
  end

  def settlement_line?(line)
    payment_line_profile(line)[:settlement]
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
      extract_tax_amount_from_tax_details(parsed_response, lines) ||
      extract_amount_from_lines(lines, /消費税|税額|tax/i)
  rescue NoMethodError, TypeError
    nil
  end

  def extract_tax_amount_from_tax_details(parsed_response, lines)
    amounts = extract_tax_details(parsed_response, lines).filter_map do |tax_detail|
      next if normalize_rate_value(tax_detail[:rate]).blank?
      next if tax_detail[:net_amount].present? && tax_detail[:net_amount].to_i <= 0

      tax_detail[:amount]
    end
    return if amounts.blank?

    amounts.sum
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

      digits = line.scan(/\d[\d,]*/).map { |value| ReceiptAmountService.parse_amount(value) }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def extract_payment_method_text(parsed_response, raw_text, lines)
    strong_line = extract_payment_method_from_lines(lines)
    return strong_line if strong_line.present?

    normalized_raw = normalize_payment_text(raw_text)
    normalized_raw_match = normalized_raw.to_s.match(payment_method_pattern)&.[](0)
    if normalized_raw_match.present? &&
        !point_or_membership_only_payment_text?(normalized_raw_match) &&
        !support_only_payment_text?(normalized_raw)
      return normalized_raw_match
    end

    nil
  end

  def extract_payment_candidates(parsed_response)
    fields = extract_fields(parsed_response)
    candidate = payment_query_candidate(fields[PAYMENT_QUERY_FIELD_NAME])

    candidate.present? ? [ candidate ] : []
  rescue NoMethodError, TypeError
    []
  end

  def payment_query_candidate(field)
    return nil unless field.is_a?(Hash)

    raw_value = field["valueString"].presence || field["content"].presence
    return nil if raw_value.blank?

    {
      source: "query_field",
      field_name: PAYMENT_QUERY_FIELD_NAME,
      method: normalize_payment_candidate_text(raw_value),
      raw_text: raw_value.to_s,
      content: field["content"].presence,
      confidence: field["confidence"]
    }.compact
  end

  def normalize_payment_candidate_text(text)
    return nil if text.blank?

    text.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip.presence
  end

  def extract_payment_method_from_lines(lines)
    profiles = Array(lines).filter_map do |line|
      profile = payment_line_profile(line)
      profile if profile[:payment_text].present?
    end

    return "現金" if profiles.any? { |profile| profile[:cash_total] }
    return "商品券" if profiles.any? { |profile| profile[:voucher] }

    card_slip_index = profiles.find_index do |profile|
      profile[:payment_text].match?(/クレジットカード売上票|カード会社|お支払方法|支払方法|payment method/i)
    end

    if card_slip_index
      focused_profiles = profiles[[ card_slip_index - 2, 0 ].max..[ card_slip_index + 5, profiles.length - 1 ].min]
      focused_match = focused_profiles.find do |profile|
        next false if profile[:point_only]
        next false if profile[:support_only]

        profile[:payment_match].present?
      end
      return focused_match[:payment_match] if focused_match.present?
    end

    payment_line = profiles.find do |profile|
      next false if profile[:point_only]
      next false if profile[:support_only]

      profile[:payment_text].match?(/支払|決済|payment/i) && profile[:payment_match].present?
    end
    return payment_line[:payment_match] if payment_line.present?

    general_match = profiles.find do |profile|
      next false if profile[:point_only]
      next false if profile[:support_only]

      profile[:payment_match].present?
    end
    general_match[:payment_match] if general_match.present?
  end

  def cash_total_line?(line)
    payment_line_profile(line)[:cash_total]
  end

  def voucher_payment_line?(line)
    payment_line_profile(line)[:voucher]
  end

  def normalize_payment_text(text)
    return nil if text.blank?

    @normalized_payment_texts ||= {}
    key = text_cache_key(text)
    @normalized_payment_texts[key] ||= key.gsub(/[[:space:]]+/, "").presence&.freeze
  end

  def point_or_membership_only_text?(text)
    normalized = normalize_payment_text(text)
    return false if normalized.blank?

    point_or_membership_only_payment_text?(normalized)
  end

  def point_or_membership_only_payment_text?(normalized)
    normalized.match?(POINT_KEYWORDS_PATTERN) && !normalized.match?(PAYMENT_KEYWORDS_PATTERN)
  end

  def support_only_payment_text?(normalized)
    normalized.match?(PAYMENT_SUPPORT_ONLY_PATTERN) && !normalized.match?(PAYMENT_TRANSACTION_CONTEXT_PATTERN)
  end

  def payment_method_pattern
    PAYMENT_METHOD_PATTERN
  end

  def payment_line_profile(line)
    @payment_line_profiles ||= {}
    raw = text_cache_key(line)

    @payment_line_profiles[raw] ||= begin
      payment_text = normalize_payment_text(raw)

      {
        raw: raw,
        normalized: raw,
        payment_text: payment_text,
        point_only: payment_text.present? && point_or_membership_only_payment_text?(payment_text),
        support_only: payment_text.present? && support_only_payment_text?(payment_text),
        cash_total: payment_text.present? && payment_text.match?(CASH_TOTAL_PATTERN),
        voucher: payment_text.present? && payment_text.match?(VOUCHER_PAYMENT_PATTERN),
        settlement: raw.match?(SETTLEMENT_LINE_PATTERN),
        payment_match: payment_text.present? ? payment_text.match(payment_method_pattern)&.[](0) : nil
      }.freeze
    end
  end

  def extract_tip_amount(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("Tip", "valueCurrency", "amount") ||
      fields.dig("Tip", "valueNumber")
  rescue NoMethodError, TypeError
    nil
  end

  def extract_currency_code(parsed_response)
    fields = extract_fields(parsed_response)

    currency_code_candidates(fields).first
  rescue NoMethodError, TypeError
    nil
  end

  def currency_code_candidates(fields)
    [
      *receipt_level_currency_codes(fields),
      *item_currency_codes(fields),
      *tax_detail_currency_codes(fields),
      *payment_currency_codes(fields)
    ].filter_map { |currency_code| normalize_currency_code(currency_code) }.uniq
  end

  def receipt_level_currency_codes(fields)
    %w[Total Subtotal TotalTax Tax Tip].filter_map do |field_name|
      fields.dig(field_name, "valueCurrency", "currencyCode")
    end
  end

  def item_currency_codes(fields)
    Array(fields.dig("Items", "valueArray")).flat_map do |item|
      value_object = item["valueObject"] || {}

      %w[TotalPrice Price].filter_map do |field_name|
        value_object.dig(field_name, "valueCurrency", "currencyCode")
      end
    end
  end

  def tax_detail_currency_codes(fields)
    Array(fields.dig("TaxDetails", "valueArray")).flat_map do |detail|
      value_object = detail["valueObject"] || {}

      %w[Amount NetAmount].filter_map do |field_name|
        value_object.dig(field_name, "valueCurrency", "currencyCode")
      end
    end
  end

  def payment_currency_codes(fields)
    Array(fields.dig("Payments", "valueArray")).filter_map do |payment|
      value_object = payment["valueObject"] || {}

      value_object.dig("Amount", "valueCurrency", "currencyCode")
    end
  end

  def normalize_currency_code(value)
    value.to_s.strip.upcase.presence
  end

  def extract_country_region(parsed_response)
    fields = extract_fields(parsed_response)
    country_region = fields.dig("CountryRegion", "valueCountryRegion") ||
      fields.dig("CountryRegion", "valueString")

    normalize_country_region(country_region)
  rescue NoMethodError, TypeError
    nil
  end

  def normalize_country_region(value)
    value.to_s.strip.upcase.presence
  end

  def extract_receipt_type(parsed_response)
    fields = extract_fields(parsed_response)

    fields.dig("ReceiptType", "valueString")
  rescue NoMethodError, TypeError
    nil
  end

  def extract_review_reasons(parsed_response)
    reasons = []
    reasons << MULTIPLE_RECEIPTS_REVIEW_REASON if multiple_receipts_suspected?(parsed_response)
    reasons
  end

  def extract_adjustment_candidates(parsed_response, lines)
    items = extract_items(parsed_response, lines)
    candidates = []

    Array(lines).each_with_index do |line, index|
      next if line.blank?

      candidates << signed_amount_candidate(lines, index, items)
      candidates << label_amount_candidate(lines, index, items)
    end

    candidates.compact
      .uniq { |candidate| [ candidate[:source_line_index], candidate[:amount], candidate[:source_text] ] }
      .first(10)
  rescue NoMethodError, TypeError
    []
  end

  def signed_amount_candidate(lines, index, items)
    line = lines[index].to_s
    return nil unless amount_only_line?(line)
    return nil unless line.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)

    label_index = nearest_label_line_index(lines, index)
    return nil if label_index.nil?

    label = lines[label_index].to_s
    return nil if adjustment_excluded_line?(label)
    return nil if item_line_candidate?(label, items) && !known_adjustment_label?(label)

    amount = adjustment_amounts_in_line(line).first
    return nil unless amount&.positive?

    sign_hint = adjustment_sign_hint(label, line)
    return nil if sign_hint == "discount" && item_discount_amount?(amount, items)

    confidence = known_adjustment_label?(label) ? 0.9 : 0.72

    build_adjustment_candidate(
      lines: lines,
      source_line_index: label_index,
      amount: amount,
      sign_hint: sign_hint,
      confidence: confidence,
      candidate_reason: "signed_amount_neighbor_label"
    )
  end

  def label_amount_candidate(lines, index, items)
    line = lines[index].to_s
    return nil if amount_only_line?(line)
    return nil if adjustment_excluded_line?(line)
    return nil if line.match?(/\d{4}[\/\-年]\s*\d{1,2}|\d{1,2}[:：]\d{2}/)

    known_label = known_adjustment_label?(line)
    signed_same_line = line.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)
    return nil if item_line_candidate?(line, items) && !known_label && !signed_same_line

    unknown_zone_label = !known_label && adjustment_zone_label?(lines, index)
    return nil unless known_label || unknown_zone_label || signed_same_line

    amount = adjustment_amounts_in_line(line).first
    reason = "label_same_line_amount"
    neighbor_signed = false

    if amount.blank?
      neighbor = neighboring_amount_line(lines, index)
      return nil if neighbor.blank?

      amount = neighbor[:amount]
      neighbor_signed = neighbor[:signed]
      reason = neighbor[:signed] ? "label_signed_neighbor_amount" : "label_next_amount"
    end

    return nil unless amount&.positive?

    sign_hint = adjustment_sign_hint(line, lines[index + 1], lines[index - 1])
    return nil if sign_hint == "discount" && reason != "label_same_line_amount" && !neighbor_signed
    return nil if sign_hint == "discount" && item_discount_amount?(amount, items)

    confidence = if known_label
      sign_hint.present? ? 0.86 : 0.78
    elsif signed_same_line
      0.78
    else
      0.55
    end

    build_adjustment_candidate(
      lines: lines,
      source_line_index: index,
      amount: amount,
      sign_hint: sign_hint,
      confidence: confidence,
      candidate_reason: reason
    )
  end

  def build_adjustment_candidate(lines:, source_line_index:, amount:, sign_hint:, confidence:, candidate_reason:)
    source_text = lines[source_line_index].to_s

    {
      source_text: source_text,
      source_line_index: source_line_index,
      neighboring_texts: {
        previous_text: source_line_index.positive? ? lines[source_line_index - 1] : nil,
        next_text: lines[source_line_index + 1]
      }.compact,
      amount: amount.to_i.abs,
      sign_hint: sign_hint,
      tax_rate_hint: adjustment_tax_rate_hint(lines, source_line_index),
      confidence: confidence,
      candidate_reason: candidate_reason,
      needs_review: true
    }.compact
  end

  def nearest_label_line_index(lines, index)
    [ index - 1, index + 1 ].find do |candidate_index|
      next false if candidate_index.negative?

      candidate = lines[candidate_index].to_s
      candidate.present? && !amount_only_line?(candidate)
    end
  end

  def neighboring_amount_line(lines, index)
    [ index + 1, index - 1 ].filter_map do |candidate_index|
      next if candidate_index.negative?

      line = lines[candidate_index].to_s
      next unless amount_only_line?(line)

      amount = adjustment_amounts_in_line(line).first
      next unless amount&.positive?

      { amount: amount, signed: line.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN) }
    end.first
  end

  def adjustment_amounts_in_line(line)
    text = line.to_s
    text.to_enum(:scan, ADJUSTMENT_MONEY_PATTERN).filter_map do |match|
      matched = Regexp.last_match
      next if percentage_amount_match?(text, matched)

      amount = ReceiptAmountService.parse_amount_or_nil(match)
      amount&.to_i&.abs
    end.select(&:positive?)
  end

  def percentage_amount_match?(text, match)
    after = text[match.end(0)..]
    after.to_s.lstrip.start_with?("%", "％")
  end

  def amount_only_line?(line)
    line.to_s.match?(ADJUSTMENT_AMOUNT_ONLY_PATTERN)
  end

  def known_adjustment_label?(line)
    text = line.to_s
    text.match?(ADJUSTMENT_DISCOUNT_LABEL_PATTERN) || text.match?(ADJUSTMENT_SURCHARGE_LABEL_PATTERN)
  end

  def adjustment_zone_label?(lines, index)
    line = lines[index].to_s
    return false if line.length > 40
    return false if line.match?(/\d{4}[\/\-年]|\d{1,2}[:：]\d{2}/)

    before_lines = lines[[ index - 4, 0 ].max...index].to_a
    after_lines = lines[(index + 1)..[ index + 5, lines.length - 1 ].min].to_a

    before_lines.any? { |candidate| candidate.to_s.match?(ADJUSTMENT_ZONE_START_PATTERN) } &&
      after_lines.any? { |candidate| candidate.to_s.match?(ADJUSTMENT_ZONE_END_PATTERN) }
  end

  def adjustment_excluded_line?(line)
    line.to_s.match?(ADJUSTMENT_EXCLUDED_LINE_PATTERN)
  end

  def item_line_candidate?(line, items)
    normalized_line = normalize_text(line)
    Array(items).any? do |item|
      item_text = normalize_text(item[:raw_text])
      next false if item_text.blank?

      normalized_line == item_text || normalized_line.include?(item_text) || item_text.include?(normalized_line)
    end
  end

  def item_discount_amount?(amount, items)
    amount = amount.to_i.abs
    return false unless amount.positive?

    Array(items).any? do |item|
      item.respond_to?(:[]) && item[:discount_amount].to_i.abs == amount
    end
  end

  def adjustment_sign_hint(*texts)
    joined = texts.compact.join(" ")
    return "discount" if joined.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)
    return "discount" if joined.match?(ADJUSTMENT_DISCOUNT_LABEL_PATTERN)
    return "surcharge" if joined.match?(ADJUSTMENT_SURCHARGE_LABEL_PATTERN)

    nil
  end

  def adjustment_tax_rate_hint(lines, source_line_index)
    context = lines[[ source_line_index - 6, 0 ].max..[ source_line_index + 6, lines.length - 1 ].min].to_a
    rates = context.filter_map do |line|
      line.to_s.scan(/(\d+(?:\.\d+)?)\s*[%％]/).map do |match|
        rate = BigDecimal(match.first) / 100
        rate.positive? ? rate : nil
      end
    end.flatten.compact.uniq

    rates.one? ? rates.first : nil
  rescue ArgumentError
    nil
  end

  def multiple_receipts_suspected?(parsed_response)
    Array(extract_analyze_result(parsed_response)["pages"]).any? do |page|
      line_boxes = receipt_line_boxes(page)
      separated_receipt_clusters?(line_boxes, page)
    end
  rescue NoMethodError, TypeError
    false
  end

  def receipt_line_boxes(page)
    Array(page["lines"]).filter_map do |line|
      content = line["content"].to_s.strip
      box = line_polygon_box(line["polygon"])
      next if content.blank? || box.blank?

      box.merge(content: content)
    end
  end

  def line_polygon_box(polygon)
    points = Array(polygon).each_slice(2).filter_map do |x, y|
      next if x.nil? || y.nil?

      [ x.to_f, y.to_f ]
    end
    return if points.size < 4

    xs = points.map(&:first)
    ys = points.map(&:last)

    {
      min_x: xs.min,
      max_x: xs.max,
      min_y: ys.min,
      max_y: ys.max,
      center_x: xs.sum / xs.size,
      center_y: ys.sum / ys.size
    }
  end

  def separated_receipt_clusters?(line_boxes, page)
    return false if line_boxes.size < MULTIPLE_RECEIPTS_MIN_LINES * 2

    page_width = page["width"].to_f
    page_height = page["height"].to_f

    horizontal_split = horizontal_cluster_split(line_boxes, page_width)
    return true if receipt_clusters?(line_boxes, horizontal_split, axis: :x)

    vertical_split = vertical_cluster_split(line_boxes, page_height)
    receipt_clusters?(line_boxes, vertical_split, axis: :y)
  end

  def horizontal_cluster_split(line_boxes, page_width)
    return if page_width <= 0

    gap = interval_gaps(line_boxes, :min_x, :max_x).max_by { |candidate| candidate[:gap] }
    return if gap.blank?
    return if gap[:gap] < page_width * MULTIPLE_RECEIPTS_HORIZONTAL_GAP_RATIO

    (gap[:before_end] + gap[:after_start]) / 2.0
  end

  def vertical_cluster_split(line_boxes, page_height)
    return if page_height <= 0

    centers = line_boxes.map { |line| line[:center_y] }.sort
    gap = centers.each_cons(2).map { |before, after| { gap: after - before, before: before, after: after } }.max_by { |candidate| candidate[:gap] }
    return if gap.blank?
    return if gap[:gap] < page_height * MULTIPLE_RECEIPTS_VERTICAL_GAP_RATIO

    (gap[:before] + gap[:after]) / 2.0
  end

  def interval_gaps(line_boxes, min_key, max_key)
    intervals = line_boxes
      .map { |line| [ line[min_key], line[max_key] ] }
      .sort_by(&:first)

    merged = []
    intervals.each do |start_position, end_position|
      if merged.empty? || start_position > merged.last.last
        merged << [ start_position, end_position ]
      else
        merged.last[1] = [ merged.last.last, end_position ].max
      end
    end

    merged.each_cons(2).map do |before, after|
      {
        gap: after.first - before.last,
        before_end: before.last,
        after_start: after.first
      }
    end
  end

  def receipt_clusters?(line_boxes, split_position, axis:)
    return false if split_position.blank?

    center_key = axis == :x ? :center_x : :center_y
    first_cluster, second_cluster = line_boxes.partition { |line| line[center_key] < split_position }
    return false unless plausible_receipt_cluster_size?(first_cluster, line_boxes.size)
    return false unless plausible_receipt_cluster_size?(second_cluster, line_boxes.size)

    receipt_anchor_cluster?(first_cluster) && receipt_anchor_cluster?(second_cluster)
  end

  def plausible_receipt_cluster_size?(cluster, total_line_count)
    cluster.size >= MULTIPLE_RECEIPTS_MIN_LINES &&
      cluster.size >= (total_line_count * MULTIPLE_RECEIPTS_MIN_CLUSTER_RATIO)
  end

  def receipt_anchor_cluster?(cluster)
    anchor_lines = cluster.count { |line| receipt_anchor_categories(line[:content]).any? }
    categories = cluster.flat_map { |line| receipt_anchor_categories(line[:content]) }.uniq

    anchor_lines >= MULTIPLE_RECEIPTS_MIN_ANCHOR_LINES &&
      categories.size >= MULTIPLE_RECEIPTS_MIN_ANCHOR_CATEGORIES &&
      categories.include?(:date_time) &&
      (categories.include?(:total) || categories.include?(:subtotal))
  end

  def receipt_anchor_categories(content)
    text = content.to_s
    categories = []
    categories << :merchant if text.match?(MERCHANT_ANCHOR_PATTERN)
    categories << :date_time if text.match?(DATETIME_ANCHOR_PATTERN)
    categories << :subtotal if text.match?(SUBTOTAL_ANCHOR_PATTERN)
    categories << :total if text.match?(TOTAL_ANCHOR_PATTERN)
    categories << :tax if text.match?(TAX_ANCHOR_PATTERN)
    categories << :payment if text.match?(PAYMENT_ANCHOR_PATTERN)
    categories
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
  rescue NoMethodError, TypeError
    []
  end

  # 税詳細は取得できる場合のみ保存し、金額計算/サマリー表示の補助情報として利用する。
  def extract_tax_details(parsed_response, lines = [])
    fields = extract_fields(parsed_response)
    details = fields.dig("TaxDetails", "valueArray")
    details = [] unless details.is_a?(Array)

    tax_detail_rates = details.filter_map do |detail|
      normalize_rate_value(detail.dig("valueObject", "Rate", "valueNumber"))
    end.uniq
    infer_target_amounts = tax_detail_rates.size > 1
    tax_details = details.map do |detail|
      value_object = detail["valueObject"] || {}
      rate = value_object.dig("Rate", "valueNumber")
      explicit_net_amount = value_object.dig("NetAmount", "valueCurrency", "amount") ||
        value_object.dig("NetAmount", "valueNumber")
      inferred_net_amount = infer_tax_detail_target_amount_from_lines(lines, rate) if infer_target_amounts && explicit_net_amount.nil?
      {
        amount: value_object.dig("Amount", "valueCurrency", "amount") || value_object.dig("Amount", "valueNumber"),
        rate: rate,
        net_amount: explicit_net_amount || inferred_net_amount,
        description: tax_detail_description(
          value_object,
          lines,
          rate: rate,
          amount: value_object.dig("Amount", "valueCurrency", "amount") || value_object.dig("Amount", "valueNumber"),
          net_amount: explicit_net_amount || inferred_net_amount
        ),
        _net_amount_inferred: explicit_net_amount.nil? && inferred_net_amount.present?
      }
    end

    inferred_from_lines = infer_included_tax_details_from_rate_targets(fields, details, lines)
    return inferred_from_lines if inferred_from_lines.present? && !complete_multi_rate_tax_details?(tax_details)

    deduplicate_inferred_tax_details(tax_details).map { |tax_detail| tax_detail.except(:_net_amount_inferred) }
  rescue NoMethodError, TypeError
    []
  end

  def complete_multi_rate_tax_details?(tax_details)
    Array(tax_details).filter_map do |tax_detail|
      rate = normalize_rate_value(tax_detail[:rate])
      amount = ReceiptAmountService.parse_amount_or_nil(tax_detail[:amount])
      net_amount = ReceiptAmountService.parse_amount_or_nil(tax_detail[:net_amount])
      rate if rate&.positive? && amount&.positive? && net_amount&.positive?
    end.uniq.size > 1
  end

  def infer_included_tax_details_from_rate_targets(fields, details, lines)
    total_amount = extract_field_amount(fields, "Total")&.to_i
    tax_amount = extract_field_amount(fields, "TotalTax")&.to_i || extract_field_amount(fields, "Tax")&.to_i
    tax_amount ||= single_summary_tax_detail_amount(details)
    return [] unless total_amount&.positive? && tax_amount&.positive?

    targets = tax_rate_targets_from_lines(lines)
    return [] unless targets.size >= 2
    return [] unless targets.sum { |target| target[:gross_amount] } == total_amount

    inferred = targets.map do |target|
      tax = included_tax_amount(target[:gross_amount], target[:rate])
      next unless tax.positive?

      {
        description: "#{rate_percentage_label(target[:rate])}%対象",
        rate: target[:rate].to_f,
        net_amount: target[:gross_amount] - tax,
        amount: tax
      }
    end
    return [] if inferred.any?(&:blank?)
    return [] unless inferred.sum { |tax_detail| tax_detail[:amount] } == tax_amount

    inferred
  end

  def extract_field_amount(fields, field_name)
    field = fields[field_name]
    return nil unless field.is_a?(Hash)

    field.dig("valueCurrency", "amount") || field["valueNumber"]
  end

  def single_summary_tax_detail_amount(details)
    return nil unless Array(details).one?

    value_object = details.first["valueObject"] || {}
    return nil if value_object.dig("Rate", "valueNumber").present?
    return nil if value_object.dig("NetAmount", "valueCurrency", "amount").present? || value_object.dig("NetAmount", "valueNumber").present?

    value_object.dig("Amount", "valueCurrency", "amount") || value_object.dig("Amount", "valueNumber")
  end

  def tax_rate_targets_from_lines(lines)
    Array(lines).each_with_index.filter_map do |line, index|
      rate = tax_target_rate_from_line(line)
      next if rate.blank?

      amount = tax_target_amount_from_line(line) || tax_target_amount_from_line(lines[index + 1])
      next unless amount&.positive?

      {
        rate: rate,
        gross_amount: amount
      }
    end.uniq { |target| [ target[:rate].to_s("F"), target[:gross_amount] ] }
  end

  def tax_target_rate_from_line(line)
    text = line.to_s
    return nil unless text.match?(/対象/)
    return nil if text.match?(/消費税|税額|tax/i)

    match = text.match(/(\d+(?:\.\d+)?)\s*[%％]/)
    normalize_rate_value(match[1]) if match
  end

  def included_tax_amount(gross_amount, rate)
    tax = BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate)
    Amounts::Rounding.apply_rounding(tax, :floor)
  end

  def tax_detail_description(value_object, lines, rate:, amount:, net_amount:)
    structured = value_object.dig("Description", "valueString") || value_object.dig("Description", "content")
    return structured.to_s.strip.presence if structured.present? && !generic_tax_detail_description?(structured)

    context = tax_detail_context_description(lines, rate:, amount:, net_amount:)

    [ context, structured ].filter_map { |value| value.to_s.strip.presence }.uniq.join(" / ").presence
  end

  def generic_tax_detail_description?(description)
    description.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, "").match?(GENERIC_TAX_DETAIL_DESCRIPTION_PATTERN)
  end

  def tax_detail_context_description(lines, rate:, amount:, net_amount:)
    normalized_rate = normalize_rate_value(rate)
    return if normalized_rate.blank?

    rate_label = rate_percentage_label(normalized_rate)
    labels = []
    labels << tax_detail_amount_context_label(lines, rate_label, net_amount) if net_amount.present?
    labels << tax_detail_amount_context_label(lines, rate_label, amount) if amount.present?

    labels.compact.uniq.join(" / ").presence
  end

  def tax_detail_amount_context_label(lines, rate_label, amount)
    normalized_amount = ReceiptAmountService.parse_amount_or_nil(amount)&.to_i
    return if normalized_amount.blank? || normalized_amount <= 0

    Array(lines).each_with_index do |line, index|
      next unless tax_detail_line_amounts(line).include?(normalized_amount)

      label = nearest_tax_detail_context_label(lines, index, rate_label)
      return label if label.present?
    end

    nil
  end

  def nearest_tax_detail_context_label(lines, amount_line_index, rate_label)
    [ -2, -1, 0, 1 ].filter_map do |offset|
      line_index = amount_line_index + offset
      next if line_index.negative? || line_index >= lines.size

      line = lines[line_index]
      next if line.blank?
      next unless tax_detail_context_label_line?(line, rate_label)

      [ offset.abs, offset.negative? ? 0 : 1, line.to_s.strip ]
    end.min_by { |entry| [ entry[0], entry[1] ] }&.last
  end

  def tax_detail_context_label_line?(line, rate_label)
    text = line.to_s
    text.match?(/#{Regexp.escape(rate_label)}\s*[%％]/) &&
      text.match?(/小\s*計|対象|消費税|税額|内税|外税|税抜|税込|tax/i)
  end

  def tax_detail_line_amounts(line)
    line.to_s.to_enum(:scan, /[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/).filter_map do |match|
      ReceiptAmountService.parse_amount_or_nil(match)&.to_i
    end
  end

  def deduplicate_inferred_tax_details(tax_details)
    tax_details.group_by { |tax_detail| tax_detail_deduplication_key(tax_detail) }.flat_map do |key, group|
      next group if key.blank? || group.size == 1

      explicit_details_with_net_amount = group.reject { |tax_detail| tax_detail[:_net_amount_inferred] }.select { |tax_detail| tax_detail[:net_amount].present? }
      next explicit_details_with_net_amount if explicit_details_with_net_amount.any?

      group.all? { |tax_detail| tax_detail[:net_amount].blank? } ? [ group.first ] : group
    end
  end

  def tax_detail_deduplication_key(tax_detail)
    rate = normalize_rate_value(tax_detail[:rate])
    amount = tax_detail[:amount]
    return if rate.blank? || amount.blank?

    [ rate.to_s("F"), amount.to_i ]
  end

  def infer_tax_detail_target_amount_from_lines(lines, rate)
    normalized_rate = normalize_rate_value(rate)
    return if normalized_rate.blank?

    rate_label = rate_percentage_label(normalized_rate)
    Array(lines).each_with_index do |line, index|
      next unless tax_target_line?(line, rate_label)

      same_line_amount = tax_target_amount_from_line(line)
      return same_line_amount if same_line_amount.present?

      neighboring_amount = tax_target_amount_from_line(lines[index + 1])
      return neighboring_amount if neighboring_amount.present?
    end

    nil
  end

  def tax_target_line?(line, rate_label)
    text = line.to_s
    text.match?(/#{Regexp.escape(rate_label)}\s*[%％].{0,8}対象/) &&
      !text.match?(/消費税|税額|tax/i)
  end

  def tax_target_amount_from_line(line)
    amounts = line.to_s.to_enum(:scan, /[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/).filter_map do |match|
      amount = ReceiptAmountService.parse_amount_or_nil(match)
      amount&.to_i
    end

    amounts.select { |amount| amount.positive? && amount > 20 }.max
  end

  def normalize_rate_value(value)
    return if value.blank?

    rate = BigDecimal(value.to_s)
    rate > 1 ? rate / 100 : rate
  rescue ArgumentError
    nil
  end

  def rate_percentage_label(rate)
    percentage = rate * 100

    percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")
  end

  def extract_items(parsed_response, lines = [])
    fields = extract_fields(parsed_response)
    items = fields.dig("Items", "valueArray")
    return [] unless items.is_a?(Array)

    discount_details_by_index = extract_discount_details_by_item_index(items, lines)

    items.filter_map.with_index do |item, index|
      value_object = item["valueObject"] || {}
      total_price = value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber")
      raw_text = value_object.dig("Description", "valueString") ||
        value_object.dig("Description", "content") ||
        item["content"]
      raw_text = clean_item_raw_text(raw_text, item)
      next if adjustment_only_item?(item, raw_text:, total_price:)

      discount_amount = discount_details_by_index.dig(index, :amount).to_i
      original_line_total = discount_details_by_index.dig(index, :original_line_total).presence || total_price
      line_total = if discount_amount.positive?
        [ normalize_amount_for_discount(original_line_total) - discount_amount, 0 ].max
      else
        original_line_total
      end

      {
        raw_text: raw_text,
        price: value_object.dig("Price", "valueCurrency", "amount") || value_object.dig("Price", "valueNumber"),
        quantity: value_object.dig("Quantity", "valueNumber"),
        quantity_unit: value_object.dig("QuantityUnit", "valueString"),
        product_code: value_object.dig("ProductCode", "valueString"),
        line_total: line_total,
        original_line_total: original_line_total,
        discount_amount: discount_amount.positive? ? discount_amount : nil,
        discount_rate: discount_details_by_index.dig(index, :rate),
        tax_rate: extract_item_tax_rate(item, value_object),
        confidence: item["confidence"]
      }
    end
  rescue NoMethodError, TypeError
    []
  end

  def adjustment_only_item?(item, raw_text:, total_price:)
    content = normalize_text(item["content"])
    normalized_raw_text = normalize_text(raw_text)

    return true if receipt_level_discount_line?(normalized_raw_text)

    total_price.blank? &&
      item_discount_keyword_line?(content) &&
      content.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)
  end

  def clean_item_raw_text(raw_text, item)
    return raw_text unless item["content"].to_s.match?(/値引|割引|discount/i)

    raw_text.to_s.lines.first&.chomp.presence || raw_text
  end

  def extract_item_tax_rate(item, value_object)
    explicit_rate = value_object.dig("TaxRate", "valueNumber") ||
      value_object.dig("Tax", "valueNumber") ||
      value_object.dig("Rate", "valueNumber")
    return explicit_rate if explicit_rate.present?

    item["content"].to_s.scan(/(\d+(?:\.\d+)?)\s*[%％]/).filter_map do |match|
      normalize_rate_value(match.first)
    end.first
  rescue NoMethodError, TypeError
    nil
  end

  # 割引検出。
  # lines上で item名 → 金額 → 割引 → 割引率 → 割引額 の順に並ぶケースを対象に、
  # 割引額・割引率・割引前金額を直前itemへ紐付ける。
  def extract_discount_details_by_item_index(items, lines)
    normalized_lines = Array(lines)
    return {} if normalized_lines.blank?

    item_labels = items.map do |item|
      value_object = item["valueObject"] || {}
      raw_text = value_object.dig("Description", "valueString") ||
          value_object.dig("Description", "content") ||
          item["content"]

      normalize_text(clean_item_raw_text(raw_text, item))
    end

    item_original_totals = items.map do |item|
      value_object = item["valueObject"] || {}
      value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber")
    end

    current_item_index = nil
    discount_target_item_index = nil
    next_item_index = 0
    waiting_discount = false
    current_discount_rate = nil
    discount_details_by_index = Hash.new { |hash, key| hash[key] = { amount: 0, rate: nil, original_line_total: nil } }

    normalized_lines.each do |line|
      if waiting_discount
        extracted_rate = extract_discount_rate_from_line(line)
        if extracted_rate
          current_discount_rate = extracted_rate
          next
        end

        matched_discount_target_index = match_discount_target_item_index_from_line(line, item_labels, current_item_index)
        if matched_discount_target_index
          discount_target_item_index = matched_discount_target_index
          next
        end

        discount_amount = extract_discount_amount_from_line(line)
        if discount_amount.positive?
          target_item_index = discount_target_item_index || current_item_index
          original_line_total = normalize_amount_for_discount(item_original_totals[target_item_index])
          detail = discount_details_by_index[target_item_index]
          detail[:amount] += discount_amount
          detail[:rate] ||= current_discount_rate
          detail[:original_line_total] ||= original_line_total if original_line_total.positive?

          waiting_discount = false
          current_discount_rate = nil
          discount_target_item_index = nil
          next
        end
      end

      matched_item_index = match_item_index_from_line(line, item_labels, next_item_index)
      if matched_item_index
        current_item_index = matched_item_index
        discount_target_item_index = nil
        next_item_index = matched_item_index + 1
        waiting_discount = false
        current_discount_rate = nil
        next
      end

      if item_discount_keyword_line?(line)
        waiting_discount = current_item_index.present?
        discount_target_item_index = current_item_index
        current_discount_rate = nil
        next
      end
    end

    discount_details_by_index
  end

  def match_discount_target_item_index_from_line(line, item_labels, current_item_index)
    return if current_item_index.blank?

    item_labels.each_with_index.first(current_item_index + 1).reverse.find do |label, _index|
      next false if label.blank?

      discount_target_line_matches_label?(line, label)
    end&.last
  end

  def discount_target_line_matches_label?(line, label)
    normalized_line = normalize_text(line)
    normalized_label = normalize_text(label)
    return true if normalized_line.include?(normalized_label) || normalized_label.include?(normalized_line)

    key = normalized_line.split(/[[:space:]　(（]/).first
    key.present? && key.length >= 2 && normalized_label.include?(key)
  end

  def match_item_index_from_line(line, item_labels, start_index)
    item_labels.each_with_index.drop(start_index).find do |label, _index|
      next false if label.blank?

      line.include?(label) || label.include?(line)
    end&.last
  end

  def item_discount_keyword_line?(line)
    return false if receipt_level_discount_line?(line)

    line.match?(/値引|割引|discount|off/i)
  end

  def receipt_level_discount_line?(line)
    line.match?(/クーポン|会員|夜間|ポイント|アプリ|coupon|member|point/i)
  end

  def extract_discount_rate_from_line(line)
    return nil if line.match?(/[-−▲]/)

    matched = line.match(/(\d+(?:\.\d+)?)\s*%/)
    return nil unless matched

    BigDecimal(matched[1]) / 100
  end

  def extract_discount_amount_from_line(line)
    return 0 unless line.match?(/[-−▲]/)

    line.scan(/\d[\d,]*/).map { |value| ReceiptAmountService.parse_amount(value) }.max.to_i
  end

  def normalize_amount_for_discount(value)
    ReceiptAmountService.parse_amount(value)
  end

  def build_error_result(error_code)
    Ocr::ResultTemplate.error_result(
      error_code: error_code,
      provider: provider,
      model_id: nil,
      polling_metrics: parsed_response_polling_metrics.presence
    )
  end

  def parsed_response_polling_metrics
    return {} unless defined?(@parsed_response) && @parsed_response.present?

    extract_polling_metrics(@parsed_response)
  end

  def cacheable_response?(parsed_response)
    defined?(@parsed_response) && parsed_response.equal?(@parsed_response)
  end

  def cache_lines(parsed_response, lines)
    @raw_lines = lines if cacheable_response?(parsed_response)
    lines
  end

  def reset_cached_response_state!
    %i[@analyze_result @document @fields @raw_lines @normalized_lines].each do |ivar|
      remove_instance_variable(ivar) if instance_variable_defined?(ivar)
    end
  end

  def text_cache_key(text)
    -text.to_s
  end
end
