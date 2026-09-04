class Ocr::ResponseParser
  MULTIPLE_RECEIPTS_REVIEW_REASON = "multiple_receipts_suspected"
  ADJUSTMENT_MONEY_PATTERN = /[▲△\-−]?\s*[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?/.freeze
  ADJUSTMENT_SIGNED_MONEY_PATTERN = /(?:\A|[\s　])(?:[▲△]|[\-−]\s*)[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?/.freeze
  ADJUSTMENT_AMOUNT_ONLY_PATTERN = /\A\s*[▲△\-−]?\s*[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?\s*\z/.freeze
  PAYMENT_QUERY_FIELD_NAME = "PaymentMethods"
  MAX_REFERENCE_PRICING_PROVIDER_SPAN = 10_000_000
  MAX_REFERENCE_PRICING_TOTAL_PAGES = 8
  MAX_REFERENCE_PRICING_TOTAL_LINES = 150
  MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES = 512
  MAX_REFERENCE_PRICING_TOTAL_AMOUNT = 999_999_999_999
  MAX_REFERENCE_PRICING_PAGE_DIMENSION = 10_000
  MAX_REFERENCE_PRICING_AUTHORITY_FIELD_NODES = 512
  MAX_REFERENCE_PRICING_AUTHORITY_ARRAY_ITEMS = 100
  MAX_REFERENCE_PRICING_AUTHORITY_HASH_ENTRIES = 100
  MAX_REFERENCE_PRICING_AUTHORITY_FIELDS = 100
  MAX_REFERENCE_PRICING_AUTHORITY_SPANS = 16
  MAX_ITEM_DISCOUNT_SOURCE_REFS = 16
  REFERENCE_PRICING_AUTHORITY_VALUE_KEYS = %w[
    content
    valueAddress
    valueCountryRegion
    valueCurrency
    valueDate
    valueNumber
    valuePhoneNumber
    valueString
    valueTime
  ].freeze
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

  def initialize(response:, provider: nil, profile: nil)
    @response = response
    @provider = provider
    @profile = profile || ReceiptAnalysisProfiles.default
  end

  def call
    reset_cached_response_state!
    parsed_response = (@parsed_response = normalize_response(@response))
    validate_response_shape!(parsed_response)
    raw_text = extract_raw_text(parsed_response)
    normalized_raw_text = normalize_text(raw_text)
    normalized_lines = normalized_lines(parsed_response)
    case_preserved_lines = case_preserved_lines(parsed_response)
    analyze_result = extract_analyze_result(parsed_response)
    structured_items = extract_fields(parsed_response).dig("Items", "valueArray")
    structured_reference_pricing_candidates = Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items: structured_items,
      profile: profile,
      content: analyze_result["content"],
      string_index_type: analyze_result["stringIndexType"],
      projection: ->(**attributes) {
        ReceiptAmountService.reference_item_extension_projection(**attributes)
      }
    )
    item_layout_descriptors = Ocr::ResponseParser::ReferencePricingItemLayoutExtractor.call(
      analyze_result: analyze_result,
      profile: profile,
      projection: ->(**attributes) {
        ReceiptAmountService.reference_item_extension_projection(**attributes)
      }
    )
    item_layout_resolution = resolve_reference_pricing_item_layout(
      structured_items:,
      structured_candidates: structured_reference_pricing_candidates,
      descriptors: item_layout_descriptors
    )
    structured_or_layout_reference_pricing_candidates = item_layout_resolution.fetch(:candidates)
    line_group_reference_pricing_candidates = if structured_reference_pricing_candidates.empty? && item_layout_descriptors.empty?
      Ocr::ResponseParser::ReferencePricingLineGroupExtractor.call(
        analyze_result: analyze_result,
        profile: profile,
        projection: ->(**attributes) {
          ReceiptAmountService.reference_item_extension_projection(**attributes)
        }
      )
    else
      []
    end
    reference_pricing_candidates = if structured_or_layout_reference_pricing_candidates.any?
      structured_or_layout_reference_pricing_candidates
    else
      line_group_reference_pricing_candidates
    end
    reference_pricing_blocks = item_layout_descriptors + line_group_reference_pricing_candidates
    authority_response = response_without_reference_pricing_block_fields(
      parsed_response,
      reference_pricing_blocks
    )
    authority_lines = lines_without_reference_pricing_blocks(
      normalized_lines,
      reference_pricing_blocks
    )
    retained_item_indexes = retained_structured_item_indexes(structured_items)
    retained_item_indexes |= item_layout_resolution.fetch(:replacement_item_indexes)
    discount_details_by_item_index = if structured_items.is_a?(Array) && structured_items.all?(Hash)
      extract_discount_details_by_item_index(structured_items, authority_lines)
    else
      {}
    end
    total_amount = extract_total_amount(
      authority_response,
      authority_lines,
      reference_pricing_candidates:
    )
    subtotal_amount = extract_subtotal_amount(
      authority_response,
      authority_lines,
      reference_pricing_candidates:
    )
    tax_detail_result = extract_tax_detail_result(authority_response, authority_lines)
    tax_details = tax_detail_result[:tax_details]
    tax_amount = extract_tax_amount(authority_response, authority_lines, tax_details:)
    adjustment_candidates = extract_adjustment_candidates(authority_response, authority_lines)
    adjustment_candidates = reject_exact_external_tax_detail_adjustments(
      adjustment_candidates,
      tax_detail_structural_metadata: tax_detail_result[:tax_detail_structural_result]
    )
    reference_pricing_candidates = promote_single_structured_item_gross_reference_pricing(
      analyze_result:,
      structured_items:,
      candidates: reference_pricing_candidates,
      retained_item_indexes:,
      receipt_total: total_amount,
      receipt_tax: tax_amount,
      tax_details:,
      adjustment_candidates:,
      discount_count: discount_details_by_item_index.size
    )
    structured_items_gross_promotion = promote_structured_items_gross_reference_pricing(
      analyze_result:,
      structured_items:,
      candidates: reference_pricing_candidates,
      retained_item_indexes:,
      receipt_total: total_amount,
      adjustment_candidates:,
      discount_count: discount_details_by_item_index.size
    )
    reference_pricing_candidates = structured_items_gross_promotion.fetch(:candidates)
    structured_items_gross_evidence = structured_items_gross_promotion[:evidence]
    reference_pricing_candidates = promote_single_item_gross_summary_reference_pricing(
      analyze_result:,
      candidates: reference_pricing_candidates,
      accepted_descriptors: item_layout_resolution.fetch(:accepted_descriptors),
      retained_item_indexes:,
      receipt_total: total_amount,
      receipt_tax: tax_amount,
      tax_details:,
      adjustment_candidates:,
      discount_count: discount_details_by_item_index.size
    )
    reference_pricing_candidates = promote_shared_basis_external_tax_reference_pricing(
      analyze_result:,
      candidates: reference_pricing_candidates,
      accepted_descriptors: item_layout_resolution.fetch(:accepted_descriptors),
      retained_item_indexes:,
      receipt_subtotal: subtotal_amount,
      receipt_total: total_amount,
      receipt_tax: tax_amount,
      tax_detail_structural_metadata: tax_detail_result[:tax_detail_structural_result],
      adjustment_candidates:,
      discount_count: discount_details_by_item_index.size
    )
    item_calculation_mode_candidates = Ocr::ResponseParser::ItemCalculationModeCandidateExtractor.call(
      analyze_result: analyze_result,
      profile: profile,
      reference_pricing_candidates: reference_pricing_candidates,
      discount_item_indexes: discount_details_by_item_index.keys,
      discount_evidence_by_item_index: discount_details_by_item_index.filter_map do |index, detail|
        [ index, detail[:calculation_mode_discount] ] if detail[:calculation_mode_discount]
      end.to_h,
      destination_item_indexes: retained_item_indexes,
      item_layout_descriptors: item_layout_resolution.fetch(:accepted_descriptors),
      reference_conflict_item_indexes: item_layout_resolution.fetch(:conflict_item_indexes)
    )
    calculation_layout = calculation_layout_fallback(
      analyze_result:,
      candidates: item_calculation_mode_candidates,
      reference_candidates: reference_pricing_candidates
    )
    calculation_fragments = if calculation_layout
      []
    else
      calculation_layout_fragments(
        analyze_result:,
        parsed_response:,
        candidates: item_calculation_mode_candidates,
        reference_candidates: reference_pricing_candidates,
        item_layout_descriptors: item_layout_resolution.fetch(:accepted_descriptors),
        discount_item_indexes: discount_details_by_item_index.keys,
        retained_item_indexes:
      )
    end
    if calculation_layout
      item_calculation_mode_candidates = calculation_layout.fetch(:candidates)
      reference_pricing_candidates = []
      structured_items_gross_evidence = nil
      reference_pricing_blocks += calculation_layout.fetch(:blocks)
      authority_response = response_without_reference_pricing_block_fields(parsed_response, reference_pricing_blocks)
      authority_lines = lines_without_reference_pricing_blocks(normalized_lines, reference_pricing_blocks)
      total_amount = extract_total_amount(authority_response, authority_lines)
      subtotal_amount = extract_subtotal_amount(authority_response, authority_lines)
      tax_detail_result = extract_tax_detail_result(authority_response, authority_lines)
      tax_details = tax_detail_result[:tax_details]
      tax_amount = extract_tax_amount(authority_response, authority_lines, tax_details:)
      adjustment_candidates = extract_adjustment_candidates(authority_response, authority_lines)
      adjustment_candidates = reject_exact_external_tax_detail_adjustments(
        adjustment_candidates,
        tax_detail_structural_metadata: tax_detail_result[:tax_detail_structural_result]
      )
    elsif calculation_fragments.any?
      item_calculation_mode_candidates += calculation_fragments.map { |entry| entry.fetch(:candidate) }
      item_calculation_mode_candidates.sort_by! { |candidate| candidate.fetch(:item_index) }
    end
    authority_raw_text = authority_lines.reject(&:blank?).join("\n")

    {
      success: normalized_raw_text.present? || normalized_lines.any?,
      raw_text: normalized_raw_text,
      lines: normalized_lines,
      case_preserved_lines: case_preserved_lines,
      candidates: {
        store_name: extract_store_name(authority_response, authority_lines),
        store_address: extract_store_address(authority_response),                                                   # MerchantAddress は取得率にばらつきあり。取得値は住所として保存/表示する
        store_address_components: extract_store_address_components(authority_response),
        store_phone_number: extract_store_phone_number(authority_response),
        purchased_at_text: Ocr::ResponseParser::PurchasedAtCandidateExtractor.call(
          fields: extract_fields(authority_response),
          lines: authority_lines,
          profile: profile
        ),
        total_amount: total_amount,
        subtotal_amount: subtotal_amount,
        tax_amount: tax_amount,
        tax_rate: extract_tax_rate(authority_response),
        payment_method_text: extract_payment_method_text(authority_response, authority_raw_text, authority_lines),
        payment_candidates: extract_payment_candidates(authority_response),
        tip_amount: extract_tip_amount(authority_response),                                                         # NOTE: Tip は日本レシートではほぼ存在せず、保存はされるが未使用に近い
        currency_code: extract_currency_code(authority_response),
        country_region: extract_country_region(authority_response),
        receipt_type: extract_receipt_type(authority_response),
        payments: extract_payments(authority_response),                                                             # NOTE: Payments[] は仕様上保存対象だが未取得ケースが多く、現在はfallbackがメイン
        tax_details: tax_details,
        tax_detail_amount_basis: tax_detail_result[:tax_detail_amount_basis],
        tax_detail_structural_metadata: tax_detail_result[:tax_detail_structural_metadata],
        adjustment_candidates: adjustment_candidates,
        reference_pricing_candidates: reference_pricing_candidates,
        reference_pricing_structured_items_gross_evidence: structured_items_gross_evidence,
        reference_pricing_block_line_indexes: reference_pricing_block_line_indexes(reference_pricing_blocks),
        item_calculation_mode_candidates: item_calculation_mode_candidates,
        item_calculation_mode_source_truncated:
          structured_items.is_a?(Array) &&
            structured_items.size > Ocr::ResponseParser::ItemCalculationModeCandidateExtractor::MAX_ITEMS,
        items: calculation_layout&.fetch(:items) || extract_items(
          authority_response,
          authority_lines,
          item_calculation_mode_candidates: item_calculation_mode_candidates,
          retained_item_indexes: retained_item_indexes,
          item_layout_descriptors: item_layout_resolution.fetch(:accepted_descriptors),
          item_calculation_mode_fragments: calculation_fragments
        ),
        review_reasons: extract_review_reasons(authority_response),
        confidence_summary: extract_confidence_summary(authority_response)
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
    Rails.logger.error("[OCR::ResponseParser] invalid_response class=#{e.class}")
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

  attr_reader :response, :provider, :profile

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

  def case_preserved_lines(parsed_response)
    return @case_preserved_lines if cacheable_response?(parsed_response) && defined?(@case_preserved_lines)

    lines = extract_lines(parsed_response).map { |line| normalize_text_preserving_case(line) }.reject(&:empty?)
    @case_preserved_lines = lines if cacheable_response?(parsed_response)
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

  def normalize_text_preserving_case(text)
    @case_preserved_texts ||= {}
    key = text_cache_key(text)
    @case_preserved_texts[key] ||= key
      .unicode_normalize(:nfkc)
      .gsub(/[[:space:]]+/, " ")
      .strip
      .freeze
  end

  def extract_store_name(parsed_response, lines)
    fields = extract_fields(parsed_response)
    merchant_name = fields.dig("MerchantName", "valueString") || fields.dig("MerchantName", "content")
    item_names = structured_item_names(fields)
    candidates = extract_store_name_candidates(lines, merchant_name)

    candidates.find do |candidate|
      Analysis.store_name_candidate_valid?(candidate, item_names: item_names)
    end
  end

  def structured_item_names(fields)
    Array(fields.dig("Items", "valueArray")).filter_map do |item|
      item.dig("valueObject", "Description", "valueString") ||
        item.dig("valueObject", "Description", "content")
    end
  rescue NoMethodError, TypeError
    []
  end

  def extract_store_name_candidates(lines, merchant_name)
    normalized_lines = Array(lines).filter_map { |line| normalize_store_name_candidate(line) }
    normalized_merchant_name = normalize_store_name_candidate(merchant_name)
    heading_candidates = Analysis.store_name_customer_facing_heading_candidates(normalized_lines)
    operator_merchant_name = Analysis.store_name_operator_legal_entity_candidate?(
      normalized_merchant_name,
      normalized_lines
    )
    branch_name = extract_branch_like_store_name(normalized_lines, merchant_name)
    if branch_like_store_name?(normalized_merchant_name) &&
        !Analysis.store_name_legal_entity_name?(normalized_merchant_name)
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
    return false if normalized.match?(profile.ocr_brand_store_name_exclusion_pattern)
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

    normalized.match?(profile.ocr_branch_like_store_name_pattern)
  end

  def store_name_noise_line?(text, allow_branch_like: false)
    normalized = normalize_store_name_candidate(text)
    return true if normalized.blank?

    compacted = normalized.gsub(/[[:space:]]+/, "")
    return true if normalized.match?(profile.ocr_store_name_noise_pattern)
    return true if compacted.match?(profile.ocr_store_name_noise_pattern)
    return true if normalized.match?(/^\d+[\d\s\/:\-()]*$/)
    return true if normalized.match?(/〒/)
    return true if normalized.match?(profile.ocr_store_name_legal_entity_noise_pattern)

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

  def resolve_reference_pricing_item_layout(structured_items:, structured_candidates:, descriptors:)
    structured_items = Array(structured_items)
    structured_candidates = Array(structured_candidates)
    descriptors = Array(descriptors)
    if structured_items.empty?
      accepted_descriptors = if descriptors.one? && layout_only_descriptor?(descriptors.sole)
        descriptors
      else
        []
      end
      return {
        candidates: accepted_descriptors.map { |descriptor| layout_reference_candidate(descriptor, item_index: 0) },
        accepted_descriptors: accepted_descriptors,
        replacement_item_indexes: [],
        conflict_item_indexes: []
      }
    end

    candidates = structured_candidates.dup
    accepted_descriptors = []
    replacement_item_indexes = []
    conflict_item_indexes = []
    structured_by_index = structured_candidates.index_by { |candidate| candidate[:item_index] }

    descriptors.each do |descriptor|
      item_index = descriptor[:structured_item_index]
      next unless item_index.is_a?(Integer) && item_index.between?(0, structured_items.size - 1)

      layout_candidate = layout_reference_candidate(descriptor, item_index:)
      next if layout_candidate.nil?

      structured_candidate = structured_by_index[item_index]
      if structured_item_layout_conflict?(
        structured_items.fetch(item_index),
        structured_candidate:,
        layout_candidate:
      )
        candidates.reject! { |candidate| candidate[:item_index] == item_index }
        conflict_item_indexes << item_index
        next
      end
      next if complete_structured_reference_pricing_candidate?(structured_candidate)

      candidates.reject! { |candidate| candidate[:item_index] == item_index }
      candidates << layout_candidate
      accepted_descriptors << descriptor
      if descriptor[:destination_kind] == "azure_layout_item"
        replacement_item_indexes << item_index
      end
    end

    {
      candidates: candidates.sort_by { |candidate| candidate[:item_index] || MAX_REFERENCE_PRICING_TOTAL_LINES },
      accepted_descriptors: accepted_descriptors,
      replacement_item_indexes: replacement_item_indexes.uniq.sort,
      conflict_item_indexes: conflict_item_indexes.uniq.sort
    }
  rescue KeyError, NoMethodError, TypeError
    {
      candidates: structured_candidates,
      accepted_descriptors: [],
      replacement_item_indexes: [],
      conflict_item_indexes: []
    }
  end

  def promote_single_structured_item_gross_reference_pricing(
    analyze_result:,
    structured_items:,
    candidates:,
    retained_item_indexes:,
    receipt_total:,
    receipt_tax:,
    tax_details:,
    adjustment_candidates:,
    discount_count:
  )
    candidates = Array(candidates)
    retained_indexes = Array(retained_item_indexes)
    return candidates unless structured_items.is_a?(Array) && structured_items.one?
    return candidates unless candidates.one?

    candidate = candidates.sole
    evidence = Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossEvidenceExtractor.call(
      analyze_result:,
      profile:,
      receipt_total:,
      receipt_tax:
    )
    policy = Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossPolicy.call(
      candidate:,
      item_count: structured_items.size,
      retained_item_indexes: retained_indexes,
      summary_gross_evidence: evidence,
      adjustment_count: Array(adjustment_candidates).size,
      discount_count:,
      competing_tax_basis_count: competing_tax_basis_count(tax_details),
      item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max
    )
    return candidates unless policy.eligible?

    promoted = candidate.deep_dup.merge(
      validation_state: "valid",
      rejection_reasons: [],
      reference_price_tax_inclusion: policy.reference_price_tax_inclusion,
      tax_inclusion_evidence: single_structured_item_gross_evidence(evidence, policy:)
    )
    [ promoted ]
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    candidates
  end

  def promote_structured_items_gross_reference_pricing(
    analyze_result:,
    structured_items:,
    candidates:,
    retained_item_indexes:,
    receipt_total:,
    adjustment_candidates:,
    discount_count:
  )
    candidates = Array(candidates)
    unchanged = { candidates:, evidence: nil }
    return unchanged unless structured_items.is_a?(Array) && structured_items.size.between?(2, 20)

    evidence = Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor.call(
      analyze_result:,
      profile:,
      receipt_total:
    )
    policy = Ocr::ResponseParser::ReferencePricingStructuredItemsGrossPolicy.call(
      candidates:,
      item_count: structured_items.size,
      retained_item_indexes: Array(retained_item_indexes),
      summary_gross_evidence: evidence,
      adjustment_count: Array(adjustment_candidates).size,
      discount_count:,
      item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max
    )
    return unchanged unless policy.eligible?

    promoted_ids = policy.candidate_ids.to_set
    promoted = candidates.map do |candidate|
      next candidate unless promoted_ids.include?(candidate[:candidate_id])

      candidate.deep_dup.merge(
        validation_state: "valid",
        rejection_reasons: [],
        reference_price_tax_inclusion: policy.reference_price_tax_inclusion,
        tax_inclusion_evidence: {
          kind: policy.member_evidence_kind,
          policy_contract_version: policy.contract_version,
          item_index: candidate[:item_index]
        }
      )
    end
    {
      candidates: promoted,
      evidence: structured_items_gross_evidence(evidence, policy:)
    }
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    unchanged
  end

  def promote_single_item_gross_summary_reference_pricing(
    analyze_result:,
    candidates:,
    accepted_descriptors:,
    retained_item_indexes:,
    receipt_total:,
    receipt_tax:,
    tax_details:,
    adjustment_candidates:,
    discount_count:
  )
    candidates = Array(candidates)
    descriptors = Array(accepted_descriptors)
    retained_indexes = Array(retained_item_indexes)
    return candidates unless descriptors.one? && retained_indexes.one?

    descriptor = descriptors.sole
    return candidates unless descriptor[:destination_kind] == "azure_structured_item"
    return candidates unless descriptor[:structured_item_index] == retained_indexes.sole

    candidate_id = descriptor.dig(:reference_pricing_candidate, :candidate_id)
    matches = candidates.select do |candidate|
      candidate.is_a?(Hash) &&
        candidate[:source_kind] == "azure_item_layout" &&
        candidate[:candidate_id] == candidate_id &&
        candidate[:item_identity] == descriptor[:item_identity] &&
        candidate[:item_index] == retained_indexes.sole
    end
    return candidates unless matches.one?

    candidate = matches.sole
    evidence = Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor.call(
      analyze_result:,
      profile:,
      receipt_total:,
      receipt_tax:,
      existing_tax_details: tax_details,
      excluded_span_ranges: [
        {
          span_start: descriptor[:block_provider_span_start],
          span_end: descriptor[:block_provider_span_end]
        }
      ]
    )
    policy = Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryPolicy.call(
      candidate:,
      item_identities: [ descriptor[:item_identity] ],
      block_candidate_ids: [ candidate_id ],
      destination_identities: [ descriptor[:item_identity] ],
      summary_gross_evidence: evidence,
      adjustment_count: Array(adjustment_candidates).size,
      discount_count: discount_count + descriptors.count { |entry| entry[:per_unit_discount_note_present] },
      competing_tax_basis_count: competing_tax_basis_count(tax_details),
      item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max
    )
    return candidates unless policy.eligible?

    promoted = candidate.deep_dup.merge(
      validation_state: "valid",
      rejection_reasons: [],
      reference_price_tax_inclusion: policy.reference_price_tax_inclusion,
      tax_inclusion_evidence: single_item_gross_summary_evidence(evidence, policy:)
    )
    candidates.map { |entry| entry.equal?(candidate) ? promoted : entry }
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    candidates
  end

  def promote_shared_basis_external_tax_reference_pricing(
    analyze_result:,
    candidates:,
    accepted_descriptors:,
    retained_item_indexes:,
    receipt_subtotal:,
    receipt_total:,
    receipt_tax:,
    tax_detail_structural_metadata:,
    adjustment_candidates:,
    discount_count:
  )
    candidates = Array(candidates)
    descriptors = Array(accepted_descriptors)
    retained_indexes = Array(retained_item_indexes)
    return candidates unless descriptors.one? && retained_indexes.one?

    descriptor = descriptors.sole
    return candidates unless descriptor[:destination_kind] == "azure_structured_item"
    return candidates unless descriptor[:structured_item_index] == retained_indexes.sole

    candidate_id = descriptor.dig(:reference_pricing_candidate, :candidate_id)
    matches = candidates.select do |candidate|
      candidate.is_a?(Hash) &&
        candidate[:source_kind] == "azure_item_layout" &&
        candidate[:candidate_id] == candidate_id &&
        candidate[:item_identity] == descriptor[:item_identity] &&
        candidate[:item_index] == retained_indexes.sole
    end
    return candidates unless matches.one?

    candidate = matches.sole
    evidence = Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxEvidenceExtractor.call(
      analyze_result:,
      profile:,
      receipt_subtotal:,
      receipt_total:,
      receipt_tax:,
      tax_detail_structural_metadata:
    )
    policy = Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxPolicy.call(
      candidate:,
      item_identities: [ descriptor[:item_identity] ],
      block_candidate_ids: [ candidate_id ],
      destination_identities: [ descriptor[:item_identity] ],
      external_tax_evidence: evidence,
      tax_detail_structural_metadata:,
      adjustment_count: Array(adjustment_candidates).size,
      discount_count: discount_count + descriptors.count { |entry| entry[:per_unit_discount_note_present] },
      item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max
    )
    return candidates unless policy.eligible?

    promoted = candidate.deep_dup.merge(
      validation_state: "valid",
      rejection_reasons: [],
      reference_price_tax_inclusion: policy.reference_price_tax_inclusion,
      tax_inclusion_evidence: shared_basis_external_tax_evidence(evidence, policy:)
    )
    candidates.map { |entry| entry.equal?(candidate) ? promoted : entry }
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    candidates
  end

  def competing_tax_basis_count(tax_details)
    rates = Array(tax_details).filter_map do |detail|
      normalize_rate_value(detail[:rate]) if detail.is_a?(Hash)
    end.uniq
    [ rates.size - 1, 0 ].max
  rescue ArgumentError, NoMethodError, TypeError
    1
  end

  def single_item_gross_summary_evidence(evidence, policy:)
    {
      kind: evidence.kind,
      string_index_type: evidence.string_index_type,
      policy_contract_version: policy.contract_version,
      summary_total: evidence.summary_total.deep_dup,
      gross_tax_target: evidence.gross_tax_target.deep_dup
    }
  end

  def single_structured_item_gross_evidence(evidence, policy:)
    {
      kind: evidence.kind,
      string_index_type: evidence.string_index_type,
      policy_contract_version: policy.contract_version,
      item_parent: evidence.item_parent.deep_dup,
      tax_detail_parent: evidence.tax_detail_parent.deep_dup,
      tax_description: evidence.tax_description.deep_dup,
      tax_amount: evidence.tax_amount.deep_dup,
      document_tax_total: evidence.document_tax_total.deep_dup,
      summary_total: evidence.summary_total.deep_dup
    }
  end

  def structured_items_gross_evidence(evidence, policy:)
    {
      kind: evidence.kind,
      string_index_type: evidence.string_index_type,
      policy_contract_version: policy.contract_version,
      candidate_members: policy.candidate_members.map(&:deep_dup),
      item_parents: evidence.item_parents.map(&:deep_dup),
      item_totals: evidence.item_totals.map(&:deep_dup),
      tax_detail_parents: evidence.tax_detail_parents.map(&:deep_dup),
      tax_descriptions: evidence.tax_descriptions.map(&:deep_dup),
      tax_amounts: evidence.tax_amounts.map(&:deep_dup),
      summary_total: evidence.summary_total.deep_dup
    }
  end

  def shared_basis_external_tax_evidence(evidence, policy:)
    {
      kind: evidence.kind,
      string_index_type: evidence.string_index_type,
      policy_contract_version: policy.contract_version,
      tax_detail_index: evidence.tax_detail_index,
      subtotal: evidence.subtotal.deep_dup,
      document_tax_total: evidence.document_tax_total.deep_dup,
      summary_total: evidence.summary_total.deep_dup
    }
  end

  def layout_only_descriptor?(descriptor)
    descriptor.is_a?(Hash) &&
      descriptor[:source_kind] == "azure_item_layout" &&
      descriptor[:destination_kind] == "azure_layout_item" &&
      descriptor[:structured_item_index].nil? &&
      descriptor[:layout_item].is_a?(Hash)
  end

  def layout_reference_candidate(descriptor, item_index:)
    return unless descriptor.is_a?(Hash) && descriptor[:source_kind] == "azure_item_layout"

    candidate = descriptor[:reference_pricing_candidate]
    return unless candidate.is_a?(Hash)

    candidate.merge(
      page_index: descriptor[:page_index],
      item_index:,
      item_identity: descriptor[:item_identity],
      destination_kind: descriptor[:destination_kind],
      structured_item_index: descriptor[:structured_item_index],
      name_line_index: descriptor[:name_line_index],
      reference_line_index: descriptor[:reference_line_index],
      reference_line_provider_span_start: descriptor[:reference_line_provider_span_start],
      reference_line_provider_span_end: descriptor[:reference_line_provider_span_end],
      per_unit_discount_note_present: descriptor[:per_unit_discount_note_present],
      purchased_quantity_line_indexes: descriptor[:purchased_quantity_line_indexes],
      printed_total_line_index: descriptor[:printed_total_line_index],
      owned_line_indexes: descriptor[:owned_line_indexes],
      block_provider_span_start: descriptor[:block_provider_span_start],
      block_provider_span_end: descriptor[:block_provider_span_end]
    )
  end

  def complete_structured_reference_pricing_candidate?(candidate)
    return false unless candidate.is_a?(Hash)
    return false unless candidate[:validation_state] == "valid"
    return false unless Array(candidate[:rejection_reasons]).empty?

    candidate.dig(:reference_price, :amount).present? &&
      candidate.dig(:reference_quantity, :amount).present? &&
      candidate.dig(:reference_quantity, :unit_code).present? &&
      candidate.dig(:purchased_quantity, :amount).present? &&
      candidate.dig(:purchased_quantity, :unit_code).present? &&
      candidate[:reference_price_tax_inclusion].present?
  end

  def structured_item_layout_conflict?(item, structured_candidate:, layout_candidate:)
    return true if structured_total_conflicts_with_layout?(item, layout_candidate)
    return false unless structured_candidate.is_a?(Hash)

    comparable_reference_pricing_values(structured_candidate).any? do |key, value|
      layout_value = comparable_reference_pricing_values(layout_candidate)[key]
      layout_value.present? && value.present? && layout_value != value
    end
  end

  def structured_total_conflicts_with_layout?(item, layout_candidate)
    value_object = item.is_a?(Hash) ? item["valueObject"] : nil
    return false unless value_object.is_a?(Hash)

    total_field = value_object["TotalPrice"]
    return false unless total_field.is_a?(Hash)

    structured_amount = total_field.dig("valueCurrency", "amount") || total_field["valueNumber"]
    return false if structured_amount.nil?

    exact_decimal_value(structured_amount) != exact_decimal_value(layout_candidate.dig(:printed_line_total, :amount))
  end

  def comparable_reference_pricing_values(candidate)
    {
      reference_price: exact_decimal_value(candidate.dig(:reference_price, :amount)),
      reference_quantity: exact_decimal_value(candidate.dig(:reference_quantity, :amount)),
      reference_unit: candidate.dig(:reference_quantity, :unit_code),
      purchased_quantity: exact_decimal_value(candidate.dig(:purchased_quantity, :amount)),
      purchased_unit: candidate.dig(:purchased_quantity, :unit_code),
      tax_inclusion: exact_tax_inclusion(candidate[:reference_price_tax_inclusion]),
      printed_line_total: exact_decimal_value(candidate.dig(:printed_line_total, :amount))
    }
  end

  def exact_decimal_value(value)
    return if value.nil?

    decimal = BigDecimal(value.to_s)
    decimal.to_s("F")
  rescue ArgumentError
    nil
  end

  def exact_tax_inclusion(value)
    value if %w[gross net].include?(value)
  end

  def calculation_layout_fallback(analyze_result:, candidates:, reference_candidates:)
    descriptors = Ocr::ResponseParser::ItemCalculationModeLayoutExtractor.call(analyze_result:, profile:)
    return if descriptors.empty?

    candidates_by_index = candidates.group_by { |candidate| candidate[:item_index] }
    reference_item_indexes = reference_candidates.filter_map do |candidate|
      candidate[:item_index] if complete_structured_reference_pricing_candidate?(candidate)
    end.to_set
    return if descriptors.all? do |descriptor|
      calculation_layout_has_complete_structured_source?(descriptor, candidates_by_index:, reference_item_indexes:)
    end

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    entries = descriptors.map.with_index do |descriptor, item_index|
      calculation_layout_entry(descriptor, item_index:, analyze_result:, mapper:)
    end
    return if entries.any?(&:nil?)

    {
      items: entries.map { |entry| entry.fetch(:item) },
      candidates: entries.filter_map { |entry| entry[:candidate] },
      blocks: descriptors.map do |descriptor|
        descriptor.slice(:block_provider_span_start, :block_provider_span_end, :owned_line_indexes)
          .merge(source_kind: "azure_calculation_layout")
      end
    }
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    nil
  end

  def calculation_layout_has_complete_structured_source?(descriptor, candidates_by_index:, reference_item_indexes:)
    indexes = descriptor[:structured_item_indexes]
    return false unless indexes.is_a?(Array) && indexes.one?

    item_index = indexes.sole
    existing = candidates_by_index.fetch(item_index, [])
    return false unless existing.one?

    modes = existing.sole.fetch(:options).map { |option| option[:pricing_source_kind] }
    modes << "reference_quantity_price" if reference_item_indexes.include?(item_index)
    descriptor.fetch(:options).all? { |option| modes.include?(option[:pricing_source_kind]) }
  end

  def calculation_layout_fragments(
    analyze_result:,
    parsed_response:,
    candidates:,
    reference_candidates:,
    item_layout_descriptors:,
    discount_item_indexes:,
    retained_item_indexes:
  )
    descriptors = Ocr::ResponseParser::ItemCalculationModeFragmentExtractor.call(analyze_result:, profile:)
    return [] if descriptors.empty?

    occupied_indexes = (candidates + reference_candidates).filter_map { |candidate| candidate[:item_index] }
    occupied_indexes += item_layout_descriptors.filter_map { |descriptor| descriptor[:structured_item_index] }
    occupied_indexes += discount_item_indexes
    consumed_indexes = descriptors.flat_map { |descriptor| descriptor.fetch(:structured_item_indexes) }
    return [] unless consumed_indexes.uniq == consumed_indexes
    return [] unless (consumed_indexes - retained_item_indexes).empty? && (consumed_indexes & occupied_indexes).empty?

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    descriptors.map do |descriptor|
      item_index = descriptor.fetch(:structured_item_index)
      entry = calculation_layout_entry(descriptor, item_index:, analyze_result:, mapper:)
      return [] if entry.nil? || entry[:candidate].nil?

      items = analyze_result.dig("documents", 0, "fields", "Items", "valueArray")
      name_item = items.fetch(item_index)
      total_index = descriptor.fetch(:total_item_index)
      total_field = items.fetch(total_index).dig("valueObject", "TotalPrice")
      entry.fetch(:item).merge!(
        tax_rate: extract_item_tax_rate(name_item, name_item.fetch("valueObject")),
        confidence: name_item["confidence"],
        **structured_source_metadata(
          parsed_response,
          total_field,
          field_path: "documents[0].fields.Items[#{total_index}].TotalPrice"
        )
      )
      entry.merge(structured_item_indexes: descriptor.fetch(:structured_item_indexes))
    end
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    []
  end

  def calculation_layout_entry(descriptor, item_index:, analyze_result:, mapper:)
    return unless descriptor[:source_provider] == "azure_calculation_layout"

    identity = descriptor.fetch(:item_identity)
    destination = calculation_layout_component(descriptor[:destination_evidence], analyze_result:, mapper:)
    return if destination.nil?
    tax_evidence = descriptor[:item_tax_evidence]
    return if tax_evidence && calculation_layout_component(tax_evidence, analyze_result:, mapper:).nil?

    options = descriptor.fetch(:options).map do |option|
      evidence = option.fetch(:evidence).to_h do |role, component|
        sanitized = calculation_layout_component(component, analyze_result:, mapper:)
        return if sanitized.nil?

        [ role, sanitized ]
      end
      source = option.fetch(:source).deep_dup
      mode = option.fetch(:pricing_source_kind)
      if mode == "reference_quantity_price"
        source[:reference_quantity_origin] = "explicit"
        evidence[:purchased_quantity] = evidence.delete(:quantity)
        evidence[:purchased_unit] = evidence.delete(:quantity_unit)
      end
      {
        proposal_id: "#{identity}_#{mode}",
        pricing_source_kind: mode,
        source: source,
        evidence: evidence
      }
    end
    total_option = options.find { |option| option[:pricing_source_kind] == "explicit_line_total" }
    layout_item = descriptor.fetch(:layout_item)
    unit = ReceiptQuantityUnit.unit_for(layout_item[:quantity_unit_code])
    item = layout_item.slice(:price, :quantity, :quantity_unit_code, :line_total, :tax_rate, :ocr_item_identity).merge(
      raw_text: layout_item.fetch(:name),
      original_line_total: layout_item[:line_total],
      quantity_unit_status: unit ? "known" : "blank"
    )
    return { item: item } if options.empty?
    return if total_option.nil?

    candidate = {
      candidate_id: "#{identity}_item_calculation_mode",
      item_identity: identity,
      item_index: item_index,
      source_provider: "azure_calculation_layout",
      provider_model_id: analyze_result["modelId"],
      provider_api_version: analyze_result["apiVersion"],
      string_index_type: analyze_result["stringIndexType"],
      source_field_path: descriptor[:source_field_path],
      provider_span_start: descriptor[:block_provider_span_start],
      provider_span_end: descriptor[:block_provider_span_end],
      destination_evidence: destination,
      printed_line_total: {
        amount: total_option.dig(:source, :line_total_amount),
        evidence: total_option.dig(:evidence, :line_total)
      },
      conflicts: [],
      options: options
    }
    { item: item, candidate: candidate }
  end

  def calculation_layout_component(evidence, analyze_result:, mapper:)
    return unless evidence.is_a?(Hash) && evidence[:page_index] == 0

    line_index = evidence[:line_index]
    return unless line_index.is_a?(Integer) && line_index.between?(0, MAX_REFERENCE_PRICING_TOTAL_LINES - 1)
    return unless evidence[:source_field_path] == "pages[0].lines[#{line_index}]"

    line = analyze_result.dig("pages", 0, "lines", line_index)
    content = analyze_result["content"]
    line_span = exact_structured_authority_span(line, content:, mapper:)
    return if line_span.nil?

    span_start = evidence[:provider_span_start]
    span_end = evidence[:provider_span_end]
    return unless span_start.is_a?(Integer) && span_end.is_a?(Integer) && span_end > span_start
    return unless span_start >= line_span.first && span_end <= line_span.last
    return unless calculation_layout_word_coverage?(evidence, analyze_result:, mapper:, line_span:)

    evidence.slice(:source_field_path, :provider_span_start, :provider_span_end)
  end

  def calculation_layout_word_coverage?(evidence, analyze_result:, mapper:, line_span:)
    word_spans = evidence[:word_spans]
    return false unless word_spans.is_a?(Array) && word_spans.size.between?(1, Ocr::ResponseParser::ItemCalculationModeLayoutExtractor::MAX_WORDS)

    words = analyze_result.dig("pages", 0, "words")
    span_start = evidence[:provider_span_start]
    span_end = evidence[:provider_span_end]
    validated = word_spans.all? do |word_span|
      next false unless word_span.is_a?(Hash)

      index = word_span[:word_index]
      next false unless index.is_a?(Integer) && index.between?(0, words.size - 1)

      word = words[index]
      word_span_start = word_span[:provider_span_start]
      word_span_end = word_span[:provider_span_end]
      next false unless word_span_start.is_a?(Integer) && word_span_end.is_a?(Integer) && word_span_end > word_span_start
      next false unless word_span_start >= line_span.first && word_span_end <= line_span.last
      next false unless word_span_start < span_end && word_span_end > span_start

      word.dig("span", "offset") == word_span_start && word.dig("span", "length") == word_span_end - word_span_start
    end
    return false unless validated
    return false unless word_spans.first[:provider_span_start] <= span_start && word_spans.last[:provider_span_end] >= span_end

    word_spans.each_cons(2).all? do |left, right|
      gap_start = left[:provider_span_end]
      gap_end = right[:provider_span_start]
      gap_start <= gap_end && mapper.slice(analyze_result["content"], offset: gap_start, length: gap_end - gap_start)&.match?(/\A[ \t]*\z/)
    end
  end

  def lines_without_reference_pricing_blocks(lines, blocks)
    source_lines = Array(lines)
    excluded_indexes = reference_pricing_block_line_indexes(blocks).select do |index|
      index < source_lines.size
    end
    return source_lines if excluded_indexes.empty?

    source_lines.each_with_index.map do |line, index|
      excluded_indexes.include?(index) ? "" : line
    end
  end

  def reference_pricing_block_line_indexes(blocks)
    Array(blocks).filter_map do |block|
      next unless block.is_a?(Hash)

      case block[:source_kind]
      when "azure_line_group"
        reference_index = block[:reference_line_index]
        purchased_index = block[:purchased_quantity_line_index]
        next unless reference_index.is_a?(Integer) && purchased_index == reference_index + 1
        next if reference_index.negative?

        [ reference_index, purchased_index ]
      when "azure_item_layout", "azure_calculation_layout"
        indexes = block[:owned_line_indexes]
        next unless indexes.is_a?(Array) && indexes.size.between?(1, MAX_REFERENCE_PRICING_TOTAL_LINES)
        next unless indexes.all? { |index| index.is_a?(Integer) && index.between?(0, MAX_REFERENCE_PRICING_TOTAL_LINES - 1) }

        indexes
      end
    end.flatten.uniq.sort
  end

  # Item-pricing blocks own item-local evidence. Azure occasionally assigns
  # receipt-level fields to the same glyphs, so those fields must prove ownership outside
  # the candidate block before any receipt authority extractor can consume them.
  def response_without_reference_pricing_block_fields(parsed_response, blocks)
    block_ranges = reference_pricing_block_ranges(blocks)
    return parsed_response if block_ranges.empty?

    analyze_result = extract_analyze_result(parsed_response)
    documents = analyze_result["documents"]
    return parsed_response unless documents.is_a?(Array) && documents.size == 1

    document = documents.sole
    return response_with_reference_pricing_authority_fields(parsed_response, {}) unless document.is_a?(Hash)

    fields = document["fields"]
    return response_with_reference_pricing_authority_fields(parsed_response, {}) unless fields.is_a?(Hash)
    return response_with_reference_pricing_authority_fields(parsed_response, {}) if
      fields.size > MAX_REFERENCE_PRICING_AUTHORITY_FIELDS

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(
      index_type: analyze_result["stringIndexType"]
    )
    content = analyze_result["content"]
    return response_with_reference_pricing_authority_fields(parsed_response, fields.slice("Items")) if mapper.nil?
    return response_with_reference_pricing_authority_fields(parsed_response, fields.slice("Items")) unless
      content.is_a?(String) && content.valid_encoding?
    if content.bytesize > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
      return response_with_reference_pricing_authority_fields(parsed_response, fields.slice("Items"))
    end

    content = content.dup.freeze
    filtered_fields = fields.each_with_object({}) do |(field_name, field), filtered|
      if field_name == "Items" || structured_authority_field_owned_outside_blocks?(
        field,
        content:,
        mapper:,
        block_ranges:,
        pages: analyze_result["pages"]
      )
        filtered[field_name] = field
      end
    end

    response_with_reference_pricing_authority_fields(parsed_response, filtered_fields)
  rescue EncodingError, ArgumentError, TypeError
    response_with_reference_pricing_authority_fields(parsed_response, {})
  end

  def response_with_reference_pricing_authority_fields(parsed_response, fields)
    analyze_result = parsed_response["analyzeResult"]
    analyze_result = {} unless analyze_result.is_a?(Hash)
    documents = analyze_result["documents"]
    document = documents.is_a?(Array) && documents.size == 1 && documents.sole.is_a?(Hash) ? documents.sole : {}
    filtered_document = document.merge("fields" => fields)
    filtered_analyze_result = analyze_result.merge("documents" => [ filtered_document ])
    parsed_response.merge("analyzeResult" => filtered_analyze_result, "fields" => {})
  rescue NoMethodError, TypeError
    { "analyzeResult" => { "documents" => [ { "fields" => {} } ] } }
  end

  def reference_pricing_block_ranges(blocks)
    Array(blocks).filter_map do |block|
      next unless block.is_a?(Hash)
      next unless %w[azure_item_layout azure_line_group azure_calculation_layout].include?(block[:source_kind])

      range_start = block[:block_provider_span_start]
      range_end = block[:block_provider_span_end]
      next unless range_start.is_a?(Integer) && range_end.is_a?(Integer)
      next unless range_start >= 0 && range_end > range_start
      next if range_start > MAX_REFERENCE_PRICING_PROVIDER_SPAN ||
        range_end > MAX_REFERENCE_PRICING_PROVIDER_SPAN

      [ range_start, range_end ]
    end
  end

  def structured_authority_field_owned_outside_blocks?(field, content:, mapper:, block_ranges:, pages:)
    return false unless field.is_a?(Hash)

    stack = [ field ]
    visited_nodes = 0
    exact_span_found = false
    until stack.empty?
      node = stack.pop
      visited_nodes += 1
      return false if visited_nodes > MAX_REFERENCE_PRICING_AUTHORITY_FIELD_NODES

      case node
      when Hash
        return false if node.size > MAX_REFERENCE_PRICING_AUTHORITY_HASH_ENTRIES

        has_authority_value = REFERENCE_PRICING_AUTHORITY_VALUE_KEYS.any? { |key| node.key?(key) }
        if node.key?("spans") || has_authority_value
          span_ranges = exact_structured_authority_span_ranges(node, content:, mapper:)
          return false if span_ranges.nil?
          return false if span_ranges.any? do |span_start, span_end|
            block_ranges.any? do |block_start, block_end|
              spans_overlap?(span_start, span_end, block_start, block_end)
            end
          end

          exact_span_found = true if has_authority_value
        end
        children = []
        node.each do |key, value|
          next if key == "spans"
          if key == "boundingRegions"
            return false unless valid_structured_authority_bounding_regions?(value, pages:)

            next
          end
          next unless value.is_a?(Hash) || value.is_a?(Array)

          children << value
        end
        return false if stack.size + children.size + visited_nodes > MAX_REFERENCE_PRICING_AUTHORITY_FIELD_NODES

        stack.concat(children)
      when Array
        return false if node.size > MAX_REFERENCE_PRICING_AUTHORITY_ARRAY_ITEMS
        return false if stack.size + node.size + visited_nodes > MAX_REFERENCE_PRICING_AUTHORITY_FIELD_NODES

        node.each do |value|
          return false unless value.is_a?(Hash) || value.is_a?(Array)

          stack << value
        end
      else
        return false
      end
    end

    exact_span_found
  end

  def exact_structured_authority_span_ranges(field, content:, mapper:)
    field_content = field["content"]
    spans = field["spans"]
    return unless field_content.is_a?(String) && field_content.valid_encoding?
    return if field_content.blank? || field_content.bytesize > MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
    return unless spans.is_a?(Array) &&
      spans.size.between?(1, MAX_REFERENCE_PRICING_AUTHORITY_SPANS) &&
      spans.all?(Hash)

    total_length = 0
    total_bytes = 0
    previous_end = nil
    fragments = []
    ranges = spans.map do |span|
      span_start = span["offset"]
      span_length = span["length"]
      return unless span_start.is_a?(Integer) && span_length.is_a?(Integer)
      return if span_start.negative? || span_length <= 0
      return if span_start > MAX_REFERENCE_PRICING_PROVIDER_SPAN ||
        span_length > MAX_REFERENCE_PRICING_PROVIDER_SPAN - span_start

      span_end = span_start + span_length
      return if previous_end && span_start < previous_end

      fragment = mapper.slice(content, offset: span_start, length: span_length)
      return unless fragment.is_a?(String) && fragment.valid_encoding?

      total_length += span_length
      total_bytes += fragment.bytesize
      return if total_length > MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES ||
        total_bytes > MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES

      previous_end = span_end
      fragments << fragment
      [ span_start, span_end ]
    end
    return unless fragments.join("\n") == field_content

    ranges
  rescue EncodingError, ArgumentError, NoMethodError, TypeError
    nil
  end

  def valid_structured_authority_bounding_regions?(regions, pages:)
    return false unless regions.is_a?(Array) &&
      regions.size.between?(1, MAX_REFERENCE_PRICING_TOTAL_PAGES)
    return false unless pages.is_a?(Array) &&
      pages.size.between?(1, MAX_REFERENCE_PRICING_TOTAL_PAGES)

    page_dimensions = pages.each_with_object({}) do |page, dimensions|
      return false unless page.is_a?(Hash)

      page_number = page["pageNumber"]
      width = page["width"]
      height = page["height"]
      return false unless page_number.is_a?(Integer) &&
        page_number.between?(1, MAX_REFERENCE_PRICING_TOTAL_PAGES)
      return false if dimensions.key?(page_number)
      return false unless valid_structured_authority_page_dimension?(width) &&
        valid_structured_authority_page_dimension?(height)

      dimensions[page_number] = [ width, height ]
    end

    regions.all? do |region|
      next false unless region.is_a?(Hash) && region.size == 2
      next false unless region.key?("pageNumber") && region.key?("polygon")

      dimensions = page_dimensions[region["pageNumber"]]
      dimensions && valid_structured_authority_polygon?(
        region["polygon"],
        page_width: dimensions[0],
        page_height: dimensions[1]
      )
    end
  rescue ArgumentError, NoMethodError, TypeError
    false
  end

  def valid_structured_authority_page_dimension?(value)
    value.is_a?(Numeric) && value.finite? && value.positive? &&
      value <= MAX_REFERENCE_PRICING_PAGE_DIMENSION
  end

  def valid_structured_authority_polygon?(polygon, page_width:, page_height:)
    return false unless polygon.is_a?(Array) && polygon.size == 8
    return false unless polygon.all? { |coordinate| coordinate.is_a?(Numeric) && coordinate.finite? }

    points = polygon.each_slice(2).to_a
    return false unless points.all? do |x, y|
      x.between?(0, page_width) && y.between?(0, page_height)
    end

    cross_products = points.each_index.map do |index|
      first = points.fetch(index)
      second = points.fetch((index + 1) % points.size)
      third = points.fetch((index + 2) % points.size)
      ((second[0] - first[0]) * (third[1] - second[1])) -
        ((second[1] - first[1]) * (third[0] - second[0]))
    end

    cross_products.all?(&:positive?) || cross_products.all?(&:negative?)
  rescue ArgumentError, NoMethodError, TypeError
    false
  end

  def exact_structured_authority_span(field, content:, mapper:)
    field_content = field["content"]
    spans = field["spans"]
    return unless field_content.is_a?(String) && field_content.valid_encoding?
    return if field_content.blank? || field_content.bytesize > MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES
    return unless spans.is_a?(Array) && spans.size == 1 && spans.sole.is_a?(Hash)

    span_start = spans.sole["offset"]
    span_length = spans.sole["length"]
    return unless span_start.is_a?(Integer) && span_length.is_a?(Integer)
    return if span_start.negative? || span_length <= 0
    return if span_start > MAX_REFERENCE_PRICING_PROVIDER_SPAN ||
      span_length > MAX_REFERENCE_PRICING_PROVIDER_SPAN - span_start
    return unless mapper.length(field_content) == span_length
    return unless mapper.slice(content, offset: span_start, length: span_length) == field_content

    [ span_start, span_start + span_length ]
  end

  def spans_overlap?(left_start, left_end, right_start, right_end)
    left_start < right_end && right_start < left_end
  end

  def extract_total_amount(parsed_response, lines, reference_pricing_candidates: [])
    line_group_candidates = Array(reference_pricing_candidates).select do |candidate|
      candidate[:source_kind] == "azure_line_group"
    end
    if line_group_candidates.any?
      return line_group_summary_total(line_group_candidates)
    end
    if strict_summary_total_required?(parsed_response, reference_pricing_candidates)
      return extract_strict_summary_total_from_response(parsed_response)
    end

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

  def line_group_summary_total(candidates)
    return unless candidates.one?

    value = candidates.sole.dig(:summary_total_corroboration, :summary_total)
    ReceiptAmountService.parse_amount_or_nil(value)&.to_i
  rescue NoMethodError, TypeError
    nil
  end

  def strict_summary_total_required?(parsed_response, candidates)
    candidates = Array(candidates)
    return false if candidates.empty?

    total_field = extract_fields(parsed_response)["Total"]
    return true unless total_field.is_a?(Hash)

    spans = total_field["spans"]
    return true unless spans.is_a?(Array) && spans.size == 1

    total_span = spans.sole
    total_start = total_span["offset"]
    total_length = total_span["length"]
    return true unless total_start.is_a?(Integer) && total_length.is_a?(Integer)
    return true if total_start.negative? || total_length.negative?
    return true if total_start > MAX_REFERENCE_PRICING_PROVIDER_SPAN ||
      total_length > MAX_REFERENCE_PRICING_PROVIDER_SPAN - total_start

    total_end = total_start + total_length
    return true if total_length.zero?
    return true unless document_total_owned_by_strict_summary_line?(
      parsed_response,
      total_field,
      total_start:,
      total_length:
    )

    reference_pricing_evidence_ranges(candidates).any? do |range_start, range_end|
      total_start < range_end && range_start < total_end
    end
  rescue NoMethodError, TypeError
    true
  end

  def document_total_owned_by_strict_summary_line?(
    parsed_response,
    total_field,
    total_start:,
    total_length:
  )
    summary = exact_strict_summary_total(parsed_response, total_field:)
    return false if summary.nil?

    document_total_evidence = summary.document_total_evidence
    return false if document_total_evidence.nil?

    line_start = document_total_evidence.fetch(:provider_span_start)
    line_end = document_total_evidence.fetch(:provider_span_end)
    total_start >= line_start && total_start + total_length <= line_end &&
      summary.amount == strict_summary_total_amount(total_field)
  rescue EncodingError, ArgumentError, TypeError
    false
  end

  def strict_summary_total_amount(total_field)
    currency = total_field["valueCurrency"]
    raw_amount = if currency
      return unless currency.is_a?(Hash) && currency["currencyCode"] == "JPY"

      currency["amount"]
    else
      total_field["valueNumber"]
    end
    return unless raw_amount.is_a?(Integer) || raw_amount.is_a?(Float)
    return if raw_amount.negative? || raw_amount > MAX_REFERENCE_PRICING_TOTAL_AMOUNT
    return if raw_amount.is_a?(Float) && (!raw_amount.finite? || raw_amount.floor != raw_amount)

    raw_amount.to_i
  rescue NoMethodError, TypeError
    nil
  end

  def extract_strict_summary_total_from_response(parsed_response)
    total_field = extract_fields(parsed_response)["Total"]
    exact_strict_summary_total(parsed_response, total_field:)&.amount
  end

  def exact_strict_summary_total(parsed_response, total_field: nil)
    analyze_result = extract_analyze_result(parsed_response)
    Ocr::ResponseParser::ReferencePricingStrictSummaryTotalExtractor.call(
      analyze_result:,
      profile:,
      total_field:
    )
  end

  def reference_pricing_evidence_ranges(candidates)
    Array(candidates).flat_map do |candidate|
      evidence = %i[reference_price reference_quantity purchased_quantity printed_line_total].filter_map do |component|
        candidate.dig(component, :evidence)
      end
      evidence << candidate[:tax_inclusion_evidence] if candidate[:tax_inclusion_evidence]
      evidence.filter_map do |entry|
        range_start = entry[:provider_span_start]
        range_end = entry[:provider_span_end]
        [ range_start, range_end ] if range_start.is_a?(Integer) && range_end.is_a?(Integer) &&
          range_start >= 0 && range_end >= range_start
      end
    end
  end

  def extract_total_amount_from_lines(lines)
    amount_candidates = Array(lines).filter_map do |line|
      next if settlement_line?(line)
      next unless line.match?(profile.ocr_total_amount_line_pattern)

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

  def extract_subtotal_amount(parsed_response, lines, reference_pricing_candidates: [])
    if Array(reference_pricing_candidates).any? { |candidate| candidate[:source_kind] == "azure_line_group" }
      return extract_subtotal_amount_from_lines(lines)
    end

    fields = extract_fields(parsed_response)

    fields.dig("Subtotal", "valueCurrency", "amount") ||
      fields.dig("Subtotal", "valueNumber") ||
      extract_subtotal_amount_from_lines(lines)
  rescue NoMethodError, TypeError
    nil
  end

  def extract_subtotal_amount_from_lines(lines)
    Array(lines).filter_map do |line|
      next unless line.match?(profile.ocr_subtotal_amount_line_pattern)

      Analysis.money_token_matches(
        text: line,
        money_pattern: ADJUSTMENT_MONEY_PATTERN,
        profile: profile,
        allow_bare_money: true
      ).map { |token| token[:amount] }.max
    end.max
  end

  def extract_tax_amount(parsed_response, lines, tax_details: nil)
    fields = extract_fields(parsed_response)

    fields.dig("TotalTax", "valueCurrency", "amount") ||
      fields.dig("TotalTax", "valueNumber") ||
      fields.dig("Tax", "valueCurrency", "amount") ||
      fields.dig("Tax", "valueNumber") ||
      extract_tax_amount_from_tax_details(parsed_response, lines, tax_details:) ||
      extract_amount_from_lines(lines, profile.ocr_tax_amount_description_pattern)
  rescue NoMethodError, TypeError
    nil
  end

  def extract_tax_amount_from_tax_details(parsed_response, lines, tax_details: nil)
    details = tax_details || extract_tax_detail_result(parsed_response, lines)[:tax_details]
    amounts = Array(details).filter_map do |tax_detail|
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
        !payment_method_excluded_text?(normalized_raw) &&
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
    analysis_profile = profile
    profiles = Array(lines).filter_map do |line|
      profile = payment_line_profile(line)
      profile if profile[:payment_text].present?
    end

    return analysis_profile.cash_label if profiles.any? { |line_profile| line_profile[:cash_total] }
    return analysis_profile.voucher_label if profiles.any? { |line_profile| line_profile[:voucher] }

    card_slip_index = profiles.find_index do |profile|
      profile[:payment_text].match?(analysis_profile.ocr_card_slip_context_pattern)
    end

    if card_slip_index
      focused_profiles = profiles[[ card_slip_index - 2, 0 ].max..[ card_slip_index + 5, profiles.length - 1 ].min]
      focused_match = focused_profiles.find do |profile|
        next false if profile[:point_only]
        next false if profile[:support_only]
        next false if profile[:payment_method_excluded]

        profile[:payment_match].present?
      end
      return focused_match[:payment_match] if focused_match.present?
    end

    payment_line = profiles.find do |profile|
      next false if profile[:point_only]
      next false if profile[:support_only]
      next false if profile[:payment_method_excluded]

      profile[:payment_text].match?(analysis_profile.ocr_payment_result_context_pattern) && profile[:payment_match].present?
    end
    return payment_line[:payment_match] if payment_line.present?

    general_match = profiles.find do |profile|
      next false if profile[:point_only]
      next false if profile[:support_only]
      next false if profile[:payment_method_excluded]

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
    normalized.match?(profile.ocr_point_keywords_pattern) && !normalized.match?(profile.ocr_payment_keywords_pattern)
  end

  def support_only_payment_text?(normalized)
    normalized.match?(profile.ocr_payment_support_only_pattern) && !normalized.match?(profile.ocr_payment_transaction_context_pattern)
  end

  def payment_method_excluded_text?(normalized)
    normalized.to_s.match?(profile.ocr_payment_method_excluded_line_pattern)
  end

  def payment_method_pattern
    profile.ocr_payment_method_pattern
  end

  def payment_line_profile(line)
    @payment_line_profiles ||= {}
    raw = text_cache_key(line)

    @payment_line_profiles[raw] ||= begin
      payment_text = normalize_payment_text(raw)
      payment_method_excluded = payment_text.present? && payment_method_excluded_text?(payment_text)

      {
        raw: raw,
        normalized: raw,
        payment_text: payment_text,
        point_only: payment_text.present? && point_or_membership_only_payment_text?(payment_text),
        support_only: payment_text.present? && support_only_payment_text?(payment_text),
        payment_method_excluded: payment_method_excluded,
        cash_total: payment_text.present? && !payment_method_excluded && payment_text.match?(profile.ocr_cash_total_pattern),
        voucher: payment_text.present? && !payment_method_excluded && payment_text.match?(profile.ocr_voucher_payment_pattern),
        settlement: raw.match?(profile.ocr_settlement_line_pattern),
        payment_match: payment_text.present? && !payment_method_excluded ? payment_text.match(payment_method_pattern)&.[](0) : nil
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

  def reject_exact_external_tax_detail_adjustments(candidates, tax_detail_structural_metadata:)
    candidates = Array(candidates)
    metadata = tax_detail_structural_metadata
    return candidates unless metadata.is_a?(Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result)
    return candidates unless metadata.source_provider ==
      Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::SOURCE_PROVIDER
    return candidates unless metadata.provider_model_id ==
      Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::SUPPORTED_MODEL_ID
    return candidates unless metadata.provider_api_version ==
      Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::SUPPORTED_API_VERSION

    tax_pairs = metadata.tax_details.filter_map do |detail|
      next unless detail.is_a?(Hash)

      tax_inclusion = detail[:tax_inclusion_evidence]
      rate = detail[:rate]
      tax_amount = detail[:tax_amount]
      next unless exact_external_tax_inclusion_evidence?(tax_inclusion, detail:)
      next unless exact_external_tax_detail_child_evidence?(rate, detail:, field_name: "Rate")
      next unless exact_external_tax_detail_child_evidence?(tax_amount, detail:, field_name: "Amount")
      next unless rate[:page_index] == tax_inclusion[:page_index]
      next unless rate[:page_index] == tax_amount[:page_index]
      next unless tax_amount[:line_index] == rate[:line_index] + 1

      [ rate[:line_index], tax_amount[:amount] ]
    end
    return candidates if tax_pairs.empty?

    candidates.reject do |candidate|
      next false unless candidate.is_a?(Hash)
      next false unless candidate[:candidate_reason] == "label_next_amount"

      amount = exact_adjustment_amount(candidate[:amount])
      tax_pairs.include?([ candidate[:source_line_index], amount ])
    end
  rescue ArgumentError, NoMethodError, TypeError
    candidates
  end

  def exact_external_tax_inclusion_evidence?(evidence, detail:)
    index = detail[:tax_detail_index]
    evidence.is_a?(Hash) &&
      evidence[:kind] == Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::EXTERNAL_TAX_EVIDENCE_KIND &&
      evidence[:tax_inclusion] == Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::EXTERNAL_TAX_INCLUSION &&
      evidence[:source_provider] == Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::SOURCE_PROVIDER &&
      evidence[:source_field_path] == "documents[0].fields.TaxDetails[#{index}].Description" &&
      evidence[:tax_detail_index] == index
  end

  def exact_external_tax_detail_child_evidence?(evidence, detail:, field_name:)
    index = detail[:tax_detail_index]
    evidence.is_a?(Hash) &&
      evidence[:source_provider] == Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::SOURCE_PROVIDER &&
      evidence[:source_field_path] == "documents[0].fields.TaxDetails[#{index}].#{field_name}" &&
      evidence[:tax_detail_index] == index &&
      evidence[:page_index].is_a?(Integer) && evidence[:page_index] >= 0 &&
      evidence[:line_index].is_a?(Integer) && evidence[:line_index] >= 0 &&
      evidence[:string_index_type].is_a?(String) &&
      evidence[:provider_span_start].is_a?(Integer) && evidence[:provider_span_start] >= 0 &&
      evidence[:provider_span_end].is_a?(Integer) &&
      evidence[:provider_span_end] > evidence[:provider_span_start]
  end

  def exact_adjustment_amount(value)
    decimal = BigDecimal(value.to_s)
    decimal.to_i if decimal.frac.zero? && decimal.between?(0, MAX_REFERENCE_PRICING_TOTAL_AMOUNT)
  rescue ArgumentError
    nil
  end

  def signed_amount_candidate(lines, index, items)
    line = lines[index].to_s
    return nil unless amount_only_line?(line)
    return nil unless line.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)

    label_index = nearest_label_line_index(lines, index)
    return nil if label_index.nil?

    label = lines[label_index].to_s
    return nil if adjustment_excluded_line?(label) && !explicit_payment_adjustment_label?(label)
    return nil if item_line_candidate?(label, items) && !known_adjustment_label?(label)

    amount = adjustment_amounts_in_line(line).first
    return nil unless amount&.positive?

    sign_hint = adjustment_sign_hint(label, line)
    return nil if sign_hint == "discount" && item_discount_source?(items, index, amount)

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
    receipt_discount = receipt_level_discount_line?(line) && line.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)
    return nil if adjustment_excluded_line?(line) && !explicit_payment_adjustment_line?(line) && !receipt_discount
    return nil if line.match?(/\d{4}[\/\-年]\s*\d{1,2}|\d{1,2}[:：]\d{2}/)

    known_label = known_adjustment_label?(line)
    signed_same_line = line.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)
    return nil if item_discount_keyword_line?(line) && !signed_same_line &&
      !line.match?(profile.adjustment_currency_evidence_pattern)
    return nil if bag_item_owned_line?(line) && !signed_same_line
    return nil if item_line_candidate?(line, items) && !known_label && !signed_same_line
    return nil if tax_detail_amount_context?(lines, index) && !known_label && !signed_same_line

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
    return nil if sign_hint == "discount" && item_discount_source?(items, index, amount)
    return nil if sign_hint == "discount" && item_discount_keyword_line?(line) &&
      [ index, index - 1, index + 1 ].any? { |line_index| item_discount_source?(items, line_index, amount) }

    confidence =
      if known_label
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
    Analysis.money_token_matches(
      text: line,
      money_pattern: ADJUSTMENT_MONEY_PATTERN,
      profile: profile,
      allow_bare_money: true
    ).map { |token| token[:amount] }
  end

  def bag_item_owned_line?(line)
    source = line.to_s.unicode_normalize(:nfkc)
    return false if source.blank?
    return false if source.match?(profile.bag_fee_owned_label_pattern)

    source.match?(profile.bag_item_owned_label_pattern)
  end

  def amount_only_line?(line)
    line.to_s.match?(ADJUSTMENT_AMOUNT_ONLY_PATTERN)
  end

  def known_adjustment_label?(line)
    text = line.to_s
    text.match?(profile.ocr_adjustment_discount_label_pattern) || text.match?(profile.ocr_adjustment_surcharge_label_pattern)
  end

  def explicit_payment_adjustment_label?(line)
    explicit_payment_adjustment_discount_label?(line) || explicit_point_usage_adjustment_label?(line)
  end

  def explicit_payment_adjustment_line?(line)
    text = line.to_s
    text.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN) && explicit_payment_adjustment_label?(text)
  end

  def explicit_payment_adjustment_discount_label?(line)
    line.to_s.match?(profile.ocr_payment_adjustment_discount_label_pattern)
  end

  def explicit_point_usage_adjustment_label?(line)
    text = line.to_s
    text.match?(profile.ocr_point_usage_adjustment_label_pattern) && !text.match?(profile.ocr_point_display_line_pattern)
  end

  def adjustment_zone_label?(lines, index)
    line = lines[index].to_s
    return false if line.length > 40
    return false if line.match?(/\d{4}[\/\-年]|\d{1,2}[:：]\d{2}/)

    before_lines = lines[[ index - 4, 0 ].max...index].to_a
    after_lines = lines[(index + 1)..[ index + 5, lines.length - 1 ].min].to_a

    before_lines.any? { |candidate| candidate.to_s.match?(profile.ocr_adjustment_zone_start_pattern) } &&
      after_lines.any? { |candidate| candidate.to_s.match?(profile.ocr_adjustment_zone_end_pattern) }
  end

  def adjustment_excluded_line?(line)
    line.to_s.match?(profile.ocr_adjustment_excluded_line_pattern)
  end

  def tax_detail_amount_context?(lines, index)
    line = lines[index].to_s
    return false unless adjustment_amounts_in_line(line).any?
    return true if tax_detail_context_label?(line)

    [ index - 2, index - 1, index + 1, index + 2 ].any? do |candidate_index|
      next false if candidate_index.negative?

      tax_detail_context_label?(lines[candidate_index].to_s)
    end
  end

  def tax_detail_context_label?(line)
    text = line.to_s
    text.match?(profile.ocr_tax_context_label_pattern) ||
      text.match?(profile.ocr_tax_target_marker_pattern) ||
      text.match?(profile.ocr_tax_amount_description_pattern)
  end

  def item_line_candidate?(line, items)
    normalized_line = normalize_text(line)
    Array(items).any? do |item|
      item_text = normalize_text(item[:raw_text])
      next false if item_text.blank?

      normalized_line == item_text || normalized_line.include?(item_text) || item_text.include?(normalized_line)
    end
  end

  def item_discount_source?(items, line_index, amount)
    Array(items).any? do |item|
      Array(item[:discount_source_refs]).any? do |source|
        source[:source_line_index] == line_index && source[:amount] == amount.to_i.abs
      end
    end
  end

  def adjustment_sign_hint(*texts)
    joined = texts.compact.join(" ")
    return "discount" if joined.match?(ADJUSTMENT_SIGNED_MONEY_PATTERN)
    return "discount" if joined.match?(profile.ocr_adjustment_discount_label_pattern)
    return "surcharge" if joined.match?(profile.ocr_adjustment_surcharge_label_pattern)

    nil
  end

  def adjustment_tax_rate_hint(lines, source_line_index)
    context = lines[[ source_line_index - 6, 0 ].max..[ source_line_index + 6, lines.length - 1 ].min].to_a
    rates = context.filter_map do |line|
      next unless line.to_s.match?(profile.ocr_tax_context_label_pattern)
      next if item_discount_keyword_line?(line)

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
    Ocr::ResponseParser::MultipleReceiptDetector.call(
      pages: extract_analyze_result(parsed_response)["pages"],
      profile: profile
    )
  rescue NoMethodError, TypeError
    false
  end

  def extract_payments(parsed_response)
    fields = extract_fields(parsed_response)
    payments = fields.dig("Payments", "valueArray")
    return [] unless payments.is_a?(Array)

    payments.map.with_index do |payment, index|
      value_object = payment["valueObject"] || {}
      amount_field = value_object["Amount"]

      {
        method: value_object.dig("Method", "valueString") || value_object.dig("Method", "content"),
        amount: amount_field&.dig("valueCurrency", "amount") || amount_field&.dig("valueNumber"),
        **structured_source_metadata(
          parsed_response,
          amount_field,
          field_path: "documents[0].fields.Payments[#{index}].Amount"
        )
      }.compact
    end
  rescue NoMethodError, TypeError
    []
  end

  # 税詳細は取得できる場合のみ保存し、金額計算/サマリー表示の補助情報として利用する。
  def extract_tax_detail_result(parsed_response, lines = [])
    fields = extract_fields(parsed_response)
    details = fields.dig("TaxDetails", "valueArray")
    details = [] unless details.is_a?(Array)
    structural_metadata = Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor.call(
      analyze_result: extract_analyze_result(parsed_response),
      profile:
    )

    tax_detail_rates = details.filter_map do |detail|
      normalize_rate_value(detail.dig("valueObject", "Rate", "valueNumber"))
    end.uniq
    infer_target_amounts = tax_detail_rates.size > 1
    tax_details = details.map.with_index do |detail, index|
      value_object = detail["valueObject"] || {}
      amount_field = value_object["Amount"]
      rate = value_object.dig("Rate", "valueNumber")
      explicit_net_amount = value_object.dig("NetAmount", "valueCurrency", "amount") ||
        value_object.dig("NetAmount", "valueNumber")
      inferred_net_amount = infer_tax_detail_target_amount_from_lines(lines, rate) if infer_target_amounts && explicit_net_amount.nil?
      {
        amount: amount_field&.dig("valueCurrency", "amount") || amount_field&.dig("valueNumber"),
        rate: rate,
        net_amount: explicit_net_amount || inferred_net_amount,
        description: tax_detail_description(
          value_object,
          lines,
          rate: rate,
          amount: value_object.dig("Amount", "valueCurrency", "amount") || value_object.dig("Amount", "valueNumber"),
          net_amount: explicit_net_amount || inferred_net_amount
        ),
        _net_amount_inferred: explicit_net_amount.nil? && inferred_net_amount.present?,
        **structured_source_metadata(
          parsed_response,
          amount_field,
          field_path: "documents[0].fields.TaxDetails[#{index}].Amount"
        )
      }
    end

    inferred_from_lines = infer_included_tax_details_from_rate_targets(fields, details, lines)
    if inferred_from_lines.present? && !complete_multi_rate_tax_details?(tax_details)
      return { tax_details: inferred_from_lines, tax_detail_amount_basis: "net" }
    end

    normalized_tax_details = deduplicate_inferred_tax_details(tax_details).map do |tax_detail|
      tax_detail.except(:_net_amount_inferred)
    end
    result = { tax_details: normalized_tax_details }
    if exact_tax_detail_structural_metadata_matches?(
      structural_metadata,
      raw_details: details,
      normalized_tax_details:,
      inferred_tax_details: tax_details
    )
      result[:tax_detail_structural_metadata] = structural_metadata.to_h
      result[:tax_detail_structural_result] = structural_metadata
    end
    result
  rescue NoMethodError, TypeError
    { tax_details: [] }
  end

  def exact_tax_detail_structural_metadata_matches?(
    metadata,
    raw_details:,
    normalized_tax_details:,
    inferred_tax_details:
  )
    return false unless metadata.is_a?(Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result)
    return false unless metadata.tax_details.size == raw_details.size
    return false unless normalized_tax_details.size == raw_details.size
    return false unless inferred_tax_details.size == raw_details.size
    return false if inferred_tax_details.any? { |detail| detail[:_net_amount_inferred] == true }

    metadata.tax_details.zip(normalized_tax_details).each_with_index.all? do |(structural, normalized), index|
      structural.fetch(:tax_detail_index) == index &&
        exact_tax_detail_metadata_rate_matches?(structural.dig(:rate, :rate), normalized[:rate]) &&
        structural.dig(:net_amount, :amount) == ReceiptAmountService.parse_amount_or_nil(normalized[:net_amount])&.to_i &&
        structural.dig(:tax_amount, :amount) == ReceiptAmountService.parse_amount_or_nil(normalized[:amount])&.to_i
    end
  rescue ArgumentError, NoMethodError, TypeError
    false
  end

  def exact_tax_detail_metadata_rate_matches?(expected, actual)
    rate = normalize_rate_value(actual)
    return false if rate.nil?

    BigDecimal(expected) == rate
  rescue ArgumentError, TypeError
    false
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
    inferred = Analysis.tax_detail_line_evidence(
      lines: lines,
      receipt_total: total_amount,
      receipt_tax: tax_amount,
      existing_tax_details: [],
      profile: profile
    )
    return [] if inferred.one? && !single_rate_target_recovery_allowed?(details)

    inferred
  end

  def single_rate_target_recovery_allowed?(details)
    Array(details).none? do |detail|
      normalize_rate_value(detail.dig("valueObject", "Rate", "valueNumber"))&.positive?
    end
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
    text = line.to_s.unicode_normalize(:nfkc)
    return nil unless text.match?(profile.analysis_tax_summary_line_pattern)
    return nil unless text.match?(profile.ocr_tax_target_marker_pattern)
    return nil if text.match?(profile.ocr_tax_amount_description_pattern)

    match = text.unicode_normalize(:nfkc).match(/(\d+(?:\.\d+)?)\s*%/)
    normalize_rate_value(match[1], percentage: true) if match
  end

  def included_tax_amount(gross_amount, rate)
    tax = BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate)
    ReceiptAmountService.apply_rounding(tax, :floor)
  end

  def tax_detail_description(value_object, lines, rate:, amount:, net_amount:)
    structured = value_object.dig("Description", "valueString") || value_object.dig("Description", "content")
    return structured.to_s.strip.presence if structured.present? && !generic_tax_detail_description?(structured)

    context = tax_detail_context_description(lines, rate:, amount:, net_amount:)

    [ context, structured ].filter_map { |value| value.to_s.strip.presence }.uniq.join(" / ").presence
  end

  def generic_tax_detail_description?(description)
    description.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, "").match?(profile.ocr_generic_tax_detail_description_pattern)
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
      text.match?(profile.ocr_tax_context_label_pattern)
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
    text = line.to_s.unicode_normalize(:nfkc)
    text.match?(profile.analysis_tax_summary_line_pattern) &&
      text.match?(profile.ocr_tax_rate_target_line_pattern(rate_label)) &&
      !text.match?(profile.ocr_tax_amount_description_pattern)
  end

  def tax_target_amount_from_line(line)
    text = line.to_s.unicode_normalize(:nfkc)
    return nil unless text.match?(profile.analysis_tax_summary_continuation_line_pattern)

    text = text.gsub(/\d+(?:\.\d+)?\s*%/, " ")
    amounts = text.to_enum(:scan, /[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/).filter_map do |match|
      amount = ReceiptAmountService.parse_amount_or_nil(match)
      amount&.to_i
    end

    amounts.select { |amount| amount.positive? && amount > 20 }.max
  end

  def normalize_rate_value(value, percentage: false)
    return if value.blank?

    text = value.to_s.unicode_normalize(:nfkc)
    percentage ||= text.include?("%")
    rate = BigDecimal(text.delete("%"))
    percentage || rate > 1 ? rate / 100 : rate
  rescue ArgumentError
    nil
  end

  def rate_percentage_label(rate)
    percentage = rate * 100

    percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")
  end

  def extract_items(
    parsed_response,
    lines = [],
    item_calculation_mode_candidates: [],
    retained_item_indexes: nil,
    item_layout_descriptors: [],
    item_calculation_mode_fragments: []
  )
    fields = extract_fields(parsed_response)
    items = fields.dig("Items", "valueArray")
    items = [] if items.nil? && Array(item_layout_descriptors).any?
    return [] unless items.is_a?(Array)

    layout_descriptors = Array(item_layout_descriptors).select { |descriptor| descriptor.is_a?(Hash) }
    if items.empty?
      descriptor = layout_descriptors.sole if layout_descriptors.one?
      layout_item = descriptor&.dig(:layout_item)
      return layout_item.is_a?(Hash) ? [ layout_item.deep_dup ] : []
    end

    discount_details_by_index = extract_discount_details_by_item_index(items, lines)
    fragment_replacements = item_calculation_mode_fragments.to_h do |entry|
      [ entry.fetch(:structured_item_indexes).min, entry.fetch(:item) ]
    end
    fragment_indexes = item_calculation_mode_fragments.flat_map { |entry| entry.fetch(:structured_item_indexes) }.to_set
    retained_item_indexes ||= retained_structured_item_indexes(items)
    retained_item_index_lookup = Array(retained_item_indexes).index_with(true)
    layout_replacements_by_index = layout_descriptors.each_with_object({}) do |descriptor, replacements|
      next unless descriptor[:destination_kind] == "azure_layout_item"

      item_index = descriptor[:structured_item_index]
      layout_item = descriptor[:layout_item]
      next unless item_index.is_a?(Integer) && item_index.between?(0, items.size - 1)
      next unless layout_item.is_a?(Hash)

      replacements[item_index] = layout_item
    end
    structured_layout_candidate_ids_by_index = Array(item_calculation_mode_candidates).each_with_object({}) do |candidate, ids|
      next unless candidate.is_a?(Hash)
      next unless candidate[:source_provider] == "azure_item_layout"
      next unless candidate[:destination_kind] == "azure_structured_item"

      item_index = candidate[:item_index]
      candidate_id = candidate[:candidate_id]
      ids[item_index] = candidate_id if item_index.is_a?(Integer) && candidate_id.is_a?(String)
    end
    layout_overlays_by_index = layout_descriptors.each_with_object({}) do |descriptor, overlays|
      next unless descriptor[:destination_kind] == "azure_structured_item"

      item_index = descriptor[:structured_item_index]
      expected_candidate_id = "#{descriptor[:candidate_id]}_item_calculation_mode"
      next unless structured_layout_candidate_ids_by_index[item_index] == expected_candidate_id

      overlays[item_index] = descriptor
    end
    item_identities_by_index = Array(item_calculation_mode_candidates).each_with_object({}) do |candidate, identities|
      next unless candidate.is_a?(Hash)

      item_index = candidate[:item_index]
      identity = candidate[:item_identity]
      identities[item_index] = identity if item_index.is_a?(Integer) && identity.is_a?(String)
    end
    count_sources_by_index = Array(item_calculation_mode_candidates).each_with_object({}) do |candidate, sources|
      next unless candidate.is_a?(Hash) && candidate[:source_provider] == "azure_structured"

      item_index = candidate[:item_index]
      options = Array(candidate[:options]).select { |option| option[:pricing_source_kind] == "count_unit_price" }
      next unless item_index.is_a?(Integer) && item_index.between?(0, items.size - 1) && options.one?

      source = options.sole[:source]
      sources[item_index] = source if ReceiptQuantityUnit.countable?(source[:quantity_unit_code])
    end

    items.filter_map.with_index do |item, index|
      next fragment_replacements[index].deep_dup if fragment_replacements.key?(index)
      next if fragment_indexes.include?(index)
      next unless retained_item_index_lookup[index]

      layout_replacement = layout_replacements_by_index[index]
      next layout_replacement.deep_dup if layout_replacement

      value_object = item["valueObject"] || {}
      count_source = count_sources_by_index[index]
      layout_overlay = layout_overlays_by_index[index]
      amount_field_name = value_object["TotalPrice"].present? ? "TotalPrice" : "Price"
      amount_field = value_object[amount_field_name]
      total_price = if layout_overlay
        ReceiptAmountService.parse_amount_or_nil(layout_overlay.dig(:printed_line_total, :amount))&.to_i
      else
        value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber")
      end
      raw_text = value_object.dig("Description", "valueString") ||
        value_object.dig("Description", "content") ||
        item["content"]
      raw_text = clean_item_raw_text(raw_text, item)
      discount_amount = discount_details_by_index.dig(index, :amount).to_i
      original_line_total = discount_details_by_index.dig(index, :original_line_total).presence || total_price
      line_total =
        if discount_amount.positive?
          [ normalize_amount_for_discount(original_line_total) - discount_amount, 0 ].max
        else
          original_line_total
        end
      purchased_quantity = layout_overlay&.dig(:reference_pricing_candidate, :purchased_quantity)
      quantity_unit_resolution = if purchased_quantity
        ReceiptQuantityUnit::Resolution.new(
          code: purchased_quantity[:unit_code],
          status: purchased_quantity[:unit_status].to_sym,
          raw: nil
        )
      elsif value_object["QuantityUnit"].nil? && count_source
        ReceiptQuantityUnit::Resolution.new(code: count_source[:quantity_unit_code], status: :known, raw: nil)
      else
        profile.resolve_quantity_unit(value_object.dig("QuantityUnit", "valueString"))
      end
      quantity_unit_code = quantity_unit_resolution.known? ? quantity_unit_resolution.code : ReceiptQuantityUnit.default_code
      source_metadata = if layout_overlay
        layout_source_metadata(parsed_response, layout_overlay.dig(:printed_line_total, :evidence))
      else
        structured_source_metadata(
          parsed_response,
          amount_field,
          field_path: "documents[0].fields.Items[#{index}].#{amount_field_name}"
        )
      end

      {
        raw_text: raw_text,
        price: count_source ? count_source[:price_amount].to_i : value_object.dig("Price", "valueCurrency", "amount") || value_object.dig("Price", "valueNumber"),
        quantity: purchased_quantity&.dig(:amount) || count_source&.dig(:quantity)&.to_i || value_object.dig("Quantity", "valueNumber"),
        quantity_unit_code: quantity_unit_code,
        quantity_unit_status: quantity_unit_resolution.status.to_s,
        **unknown_quantity_unit_diagnostic(quantity_unit_resolution),
        product_code: value_object.dig("ProductCode", "valueString"),
        line_total: line_total,
        original_line_total: original_line_total,
        discount_amount: discount_amount.positive? || discount_details_by_index.dig(index, :calculation_mode_discount) ? discount_amount : nil,
        discount_rate: discount_details_by_index.dig(index, :rate),
        discount_source_refs: discount_details_by_index.dig(index, :source_refs),
        tax_rate: extract_item_tax_rate(item, value_object),
        confidence: item["confidence"],
        ocr_item_identity: item_identities_by_index[index],
        **source_metadata
      }
    end
  rescue NoMethodError, TypeError
    []
  end

  def retained_structured_item_indexes(items)
    return [] unless items.is_a?(Array)

    items.filter_map.with_index do |item, index|
      next unless item.is_a?(Hash)

      value_object = item["valueObject"]
      next unless value_object.is_a?(Hash)

      total_price = value_object.dig("TotalPrice", "valueCurrency", "amount") ||
        value_object.dig("TotalPrice", "valueNumber")
      raw_text = value_object.dig("Description", "valueString") ||
        value_object.dig("Description", "content") ||
        item["content"]
      raw_text = clean_item_raw_text(raw_text, item)
      index unless adjustment_only_item?(item, raw_text:, total_price:)
    rescue EncodingError, NoMethodError, TypeError
      nil
    end
  end

  def unknown_quantity_unit_diagnostic(resolution)
    return {} unless resolution.unknown?

    raw = resolution.raw.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      .delete("\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F")
    raw = raw.byteslice(0, 64).to_s
    raw = raw.byteslice(0, raw.bytesize - 1).to_s until raw.valid_encoding?

    { quantity_unit_raw: raw }
  rescue EncodingError
    { quantity_unit_raw: "" }
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
    return raw_text unless item["content"].to_s.match?(profile.ocr_item_discount_keyword_pattern)

    raw_text.to_s.lines.first&.chomp.presence || raw_text
  end

  def extract_item_tax_rate(item, value_object)
    explicit_rate = value_object.dig("TaxRate", "valueNumber") ||
      value_object.dig("Tax", "valueNumber") ||
      value_object.dig("Rate", "valueNumber")
    return explicit_rate if explicit_rate.present?

    lines = item["content"].to_s.unicode_normalize(:nfkc).lines
    rates = lines.each_with_index.flat_map do |line, index|
      if index.positive? && item_discount_keyword_line?(lines[index - 1]) && line.strip.match?(/\A\d+(?:\.\d+)?\s*%\z/)
        next []
      end

      line.chomp.to_enum(:scan, profile.ocr_item_tax_rate_pattern).filter_map do
        normalize_rate_value(Regexp.last_match[:rate], percentage: true)
      end
    end.uniq
    rates.sole if rates.one?
  rescue NoMethodError, TypeError
    nil
  end

  def structured_source_metadata(parsed_response, field, field_path:)
    extractor = if cacheable_response?(parsed_response)
      @structured_source_metadata_extractor ||= build_structured_source_metadata_extractor(parsed_response)
    else
      build_structured_source_metadata_extractor(parsed_response)
    end

    extractor.call(field:, field_path:)
  end

  def layout_source_metadata(parsed_response, evidence)
    return {} unless evidence.is_a?(Hash)
    return {} unless evidence[:source_provider] == "azure_item_layout"

    page_index = evidence[:page_index]
    line_index = evidence[:line_index]
    return {} unless page_index.is_a?(Integer) && page_index.zero?
    return {} unless line_index.is_a?(Integer) && line_index.between?(0, MAX_REFERENCE_PRICING_TOTAL_LINES - 1)
    return {} unless evidence[:source_field_path] == "pages[#{page_index}].lines[#{line_index}]"

    line = extract_analyze_result(parsed_response).dig("pages", page_index, "lines", line_index)
    spans = line.is_a?(Hash) ? line["spans"] : nil
    return {} unless spans.is_a?(Array) && spans.one? && spans.sole.is_a?(Hash)

    line_start = spans.sole["offset"]
    line_length = spans.sole["length"]
    source_start = evidence[:provider_span_start]
    source_end = evidence[:provider_span_end]
    return {} unless [ line_start, line_length, source_start, source_end ].all?(Integer)
    return {} unless line_start >= 0 && line_length.positive?
    return {} unless source_start >= line_start && source_end > source_start
    return {} unless source_end <= line_start + line_length

    {
      source_provider: evidence[:source_provider],
      source_field_path: evidence[:source_field_path],
      source_line_index: line_index,
      source_span_start: source_start - line_start,
      source_span_end: source_end - line_start
    }
  rescue NoMethodError, TypeError
    {}
  end

  def build_structured_source_metadata_extractor(parsed_response)
    Ocr::ResponseParser::StructuredSourceMetadataExtractor.new(
      pages: extract_analyze_result(parsed_response)["pages"],
      text_normalizer: method(:normalize_text)
    )
  end

  def extract_discount_details_by_item_index(items, lines)
    return extract_structured_item_discounts(items, lines) if items.any? { |item| item.key?("spans") }

    extract_unstructured_item_discounts(items, lines)
  end

  def extract_structured_item_discounts(items, lines)
    purchase_indexes = retained_structured_item_indexes(items)
    labels = items.each_with_index.map do |item, index|
      next unless purchase_indexes.include?(index)

      normalize_text(item.dig("valueObject", "Description", "valueString") || item.dig("valueObject", "Description", "content"))
    end
    details = {}
    structured_discount_line_groups(items, lines).each do |index, entries|
      waiting_discount = false
      current_rate = nil
      target_index = nil
      pending_sources = []

      entries.each do |entry|
        line = entry[:text]
        break if receipt_level_discount_line?(line) || line.match?(profile.analysis_previous_subtotal_context_pattern)

        if item_discount_keyword_line?(line)
          waiting_discount = true
          current_rate = nil
          target_index = index if purchase_indexes.include?(index)
          pending_sources = []
        end
        next unless waiting_discount

        current_rate = extract_discount_rate_from_line(line) || current_rate
        pending_sources.concat(discount_source_refs(line, entry[:line_index]))
        break if pending_sources.size > MAX_ITEM_DISCOUNT_SOURCE_REFS
        next if line.match?(profile.ocr_item_discount_per_unit_note_pattern)

        amount = extract_discount_amount_from_line(line)
        if amount.nil?
          unless item_discount_keyword_line?(line) || extract_discount_rate_from_line(line)
            matches = labels.each_index.select { |label_index| labels[label_index].present? && discount_target_line_matches_label?(line, labels[label_index]) }
            target_index = matches.one? ? matches.sole : nil
          end
          next
        end
        next if target_index.nil?

        detail = (details[target_index] ||= { amount: 0, rate: nil, original_line_total: nil, amount_lines: [], source_refs: [] })
        detail[:amount] += amount
        detail[:rate] ||= current_rate
        detail[:amount_lines] << line
        detail[:source_refs].concat(pending_sources)
        waiting_discount = false
      end
    end
    details.filter_map do |index, detail|
      next if detail[:amount_lines].empty? || detail[:source_refs].size > MAX_ITEM_DISCOUNT_SOURCE_REFS

      total = items[index].dig("valueObject", "TotalPrice") || {}
      detail[:original_line_total] = total.dig("valueCurrency", "amount") || total["valueNumber"]
      reconcile_discount_total_stage(items, index, detail)
      detail[:source_refs] = [] unless detail[:amount].positive? || detail[:calculation_mode_discount]
      detail.delete(:amount_lines)
      [ index, detail ]
    end.to_h
  end

  def structured_discount_line_groups(items, lines)
    return {} if items.size > MAX_REFERENCE_PRICING_AUTHORITY_ARRAY_ITEMS

    analyze_result = extract_analyze_result(@parsed_response)
    return {} unless analyze_result["modelId"] == "prebuilt-receipt" && analyze_result["apiVersion"] == "2024-11-30"

    content = analyze_result["content"]
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    return {} unless mapper && content.is_a?(String) && mapper.length(content)

    parents = items.each_with_index.flat_map do |item, index|
      spans = discount_parent_spans(item, content:, mapper:)
      return {} unless spans && item["content"].is_a?(String)
      return {} unless spans.map { |start, finish| mapper.slice(content, offset: start, length: finish - start) }.join("\n") == item["content"]

      spans.map { |start, finish| [ start, finish, index ] }
    end.sort
    return {} if parents.each_cons(2).any? { |left, right| left[1] > right[0] }

    pages = analyze_result["pages"]
    return {} unless pages.is_a?(Array) && pages.size <= MAX_REFERENCE_PRICING_TOTAL_PAGES

    source_lines = pages.flat_map do |page|
      entries = page.is_a?(Hash) ? page["lines"] : nil
      return {} unless entries.is_a?(Array) && entries.size <= MAX_REFERENCE_PRICING_TOTAL_LINES

      entries.select { |entry| entry.is_a?(Hash) && entry["content"].is_a?(String) && normalize_text(entry["content"]).present? }
    end
    return {} unless source_lines.size == lines.size

    source_lines.each_with_index.each_with_object({}) do |(line, index), groups|
      next if lines[index].blank?
      return {} unless normalize_text(line["content"]) == lines[index]

      span = exact_structured_authority_span(line, content:, mapper:)
      next unless span

      parent_index = (parents.bsearch_index { |parent| parent[0] > span[0] } || parents.size) - 1
      next if parent_index.negative?

      parent = parents[parent_index]
      next unless span[1] <= parent[1]

      (groups[parent[2]] ||= []) << { text: lines[index], line_index: index }
    end
  end

  def discount_source_refs(line, line_index)
    Analysis.money_token_matches(
      text: line,
      money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
      profile: profile,
      allow_bare_money: false
    ).filter_map do |token|
      next unless token[:raw_text].match?(/[▲△\-−]/)

      {
        source_line_index: line_index,
        source_span_start: token[:span_start],
        source_span_end: token[:span_end],
        amount: token[:amount]
      }
    end
  end

  # Provider spanを持たない旧入力だけは、完全な商品ラベルを境界として扱う。
  def extract_unstructured_item_discounts(items, lines)
    normalized_lines = Array(lines)
    return {} if normalized_lines.blank?

    item_labels = items.map do |item|
      value_object = item["valueObject"] || {}
      raw_text = value_object.dig("Description", "valueString") ||
          value_object.dig("Description", "content") ||
          item["content"]

      normalize_text(clean_item_raw_text(raw_text, item))
    end

    purchase_indexes = retained_structured_item_indexes(items).index_with(true)
    purchase_labels = item_labels.each_with_index.map { |label, index| purchase_indexes[index] ? label : nil }
    item_original_totals = items.map do |item|
      value_object = item["valueObject"] || {}
      value_object.dig("TotalPrice", "valueCurrency", "amount") || value_object.dig("TotalPrice", "valueNumber")
    end

    current_item_index = nil
    discount_target_item_index = nil
    next_item_index = 0
    waiting_discount = false
    current_discount_rate = nil
    discount_details_by_index = Hash.new { |hash, key| hash[key] = { amount: 0, rate: nil, original_line_total: nil, amount_lines: [] } }

    normalized_lines.each do |line|
      matched_item_index = match_item_index_from_line(line, purchase_labels, next_item_index)
      if matched_item_index
        current_item_index = matched_item_index
        discount_target_item_index = nil
        next_item_index = matched_item_index + 1
        waiting_discount = false
        current_discount_rate = nil
        next
      end

      if receipt_level_discount_line?(line) || line.match?(profile.analysis_previous_subtotal_context_pattern)
        waiting_discount = false
        current_discount_rate = nil
        discount_target_item_index = nil
        current_item_index = nil
        next
      elsif item_discount_keyword_line?(line)
        waiting_discount = current_item_index.present?
        discount_target_item_index = current_item_index
        current_discount_rate = nil
      end

      next unless waiting_discount
      next if line.match?(profile.ocr_item_discount_per_unit_note_pattern)

      extracted_rate = extract_discount_rate_from_line(line)
      current_discount_rate = extracted_rate if extracted_rate
      discount_amount = extract_discount_amount_from_line(line)
      if discount_amount.nil?
        matched_discount_target_index = match_discount_target_item_index_from_line(line, item_labels, current_item_index)
        discount_target_item_index = matched_discount_target_index if matched_discount_target_index
        next
      end

      target_item_index = discount_target_item_index || current_item_index
      original_line_total = ReceiptAmountService.parse_amount_or_nil(item_original_totals[target_item_index])
      detail = discount_details_by_index[target_item_index]
      detail[:amount] += discount_amount
      detail[:rate] ||= current_discount_rate
      detail[:original_line_total] ||= original_line_total unless original_line_total.nil?
      detail[:amount_lines] << line

      waiting_discount = false
      current_discount_rate = nil
      discount_target_item_index = nil
    end

    discount_details_by_index.each do |index, detail|
      reconcile_discount_total_stage(items, index, detail)
      detail.delete(:amount_lines)
    end
    discount_details_by_index
  end

  def reconcile_discount_total_stage(items, index, detail)
    return unless items.size <= MAX_REFERENCE_PRICING_AUTHORITY_ARRAY_ITEMS

    item = items[index]
    analyze_result = extract_analyze_result(@parsed_response)
    pages = analyze_result["pages"]
    pages = [] unless pages.is_a?(Array) && pages.size <= MAX_REFERENCE_PRICING_TOTAL_PAGES

    total = item.dig("valueObject", "TotalPrice")
    total_amount = normalize_amount_for_discount(detail[:original_line_total])
    post_discount_lines = pages.flat_map do |page|
      lines = page.is_a?(Hash) ? page["lines"] : nil
      next [] unless lines.is_a?(Array) && lines.size <= MAX_REFERENCE_PRICING_TOTAL_LINES

      lines.each_cons(2).filter_map do |discount_line, total_line|
        next unless discount_line.is_a?(Hash) && total_line.is_a?(Hash)
        next unless detail[:amount_lines].include?(normalize_text(discount_line["content"]))

        match = profile.ocr_reference_pricing_item_layout_printed_total_line_pattern.match(total_line["content"].to_s)
        next unless match && normalize_amount_for_discount(match[:amount]) == total_amount

        [ discount_line, total_line ]
      end
    end
    if post_discount_lines.empty? && !printed_total_after_discount?(item, detail)
      detail[:calculation_mode_discount] = before_item_discount_evidence(analyze_result, items, index, detail)
      return
    end

    other_items = items.each_with_index.filter_map { |other, other_index| other unless other_index == index }
    exact_lines = post_discount_lines.select do |discount_line, total_line|
      exact_post_discount_total?(analyze_result, item, total, discount_line, total_line, detail, other_items:)
    end
    if exact_lines.one? && total_amount + detail[:amount] <= MAX_REFERENCE_PRICING_TOTAL_AMOUNT
      detail[:original_line_total] = total_amount + detail[:amount]
      detail[:calculation_mode_discount] = calculation_mode_discount_evidence(
        analyze_result, exact_lines.sole.first, index, detail
      )
    else
      detail[:amount] = 0
      detail[:rate] = nil
    end
  end

  def printed_total_after_discount?(item, detail)
    content = item["content"].to_s
    return true unless content.valid_encoding? && content.bytesize <= Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES

    discount_seen = false
    content.each_line.any? do |line|
      discount_seen ||= detail[:amount_lines].include?(normalize_text(line))
      next false unless discount_seen

      match = profile.ocr_reference_pricing_item_layout_printed_total_line_pattern.match(line.chomp)
      match && normalize_amount_for_discount(match[:amount]) == detail[:original_line_total]
    end
  end

  def exact_post_discount_total?(analyze_result, item, total, discount_line, total_line, detail, other_items:)
    return false unless detail[:amount_lines].one? && total.is_a?(Hash)
    return false unless analyze_result["modelId"] == "prebuilt-receipt" && analyze_result["apiVersion"] == "2024-11-30"

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    content = analyze_result["content"]
    return false unless mapper && content.is_a?(String) && mapper.length(content)
    total_content = total["content"]
    return false unless total_content.is_a?(String) && total_content.valid_encoding?
    return false unless total_content.unicode_normalize(:nfkc).match?(ADJUSTMENT_AMOUNT_ONLY_PATTERN)
    return false unless normalize_amount_for_discount(total["content"]) == detail[:original_line_total]

    total_span = exact_structured_authority_span(total, content:, mapper:)
    discount_span = exact_structured_authority_span(discount_line, content:, mapper:)
    total_line_span = exact_structured_authority_span(total_line, content:, mapper:)
    parent_spans = discount_parent_spans(item, content:, mapper:)
    return false if [ total_span, discount_span, total_line_span, parent_spans ].any?(&:nil?)
    return false unless total_span[0] >= total_line_span[0] && total_span[1] <= total_line_span[1]
    return false unless discount_span[1] <= total_line_span[0]
    return false unless [ total_span, discount_span ].all? do |span|
      parent_spans.any? { |parent| span[0] >= parent[0] && span[1] <= parent[1] }
    end

    other_items.none? do |other|
      other_parent_spans = discount_parent_spans(other, content:, mapper:)
      return false unless other_parent_spans

      other_parent_spans.any? do |parent|
        [ total_span, discount_span ].any? { |span| spans_overlap?(*span, *parent) }
      end
    end
  end

  def discount_parent_spans(item, content:, mapper:)
    spans = item.is_a?(Hash) ? item["spans"] : nil
    return unless spans.is_a?(Array) && spans.any? && spans.size <= MAX_REFERENCE_PRICING_AUTHORITY_ARRAY_ITEMS

    ranges = spans.map do |span|
      return unless span.is_a?(Hash)

      offset = span["offset"]
      length = span["length"]
      return unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length.positive?
      return unless offset <= MAX_REFERENCE_PRICING_PROVIDER_SPAN && length <= MAX_REFERENCE_PRICING_PROVIDER_SPAN - offset
      return unless mapper.slice(content, offset:, length:)

      [ offset, offset + length ]
    end.sort
    return if ranges.each_cons(2).any? { |left, right| left[1] > right[0] }

    ranges
  end

  def calculation_mode_discount_evidence(analyze_result, line, item_index, detail)
    raw_content = line["content"]
    return unless raw_content.is_a?(String) && raw_content.valid_encoding?
    return if raw_content.bytesize > MAX_REFERENCE_PRICING_TOTAL_FIELD_BYTES

    match = profile.ocr_item_calculation_discount_line_pattern.match(raw_content)
    return unless match && %i[rate amount].all? { |key| match[key].bytesize <= 64 }

    rate = BigDecimal(match[:rate].unicode_normalize(:nfkc)) / 100
    amount = BigDecimal(match[:amount].unicode_normalize(:nfkc).delete(","))
    rate_text = rate.to_s("F").sub(/0+\z/, "").sub(/\.\z/, "")
    return unless rate.positive? && rate < 1 && rate_text.split(".").last.length <= 3
    return unless amount.between?(0, MAX_REFERENCE_PRICING_TOTAL_AMOUNT)
    return unless rate == detail[:rate] && amount == detail[:amount]

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    line_span = exact_structured_authority_span(line, content: analyze_result["content"], mapper:)
    return unless line_span

    evidence = %i[rate amount].to_h do |key|
      span = mapper.span_for_bytes(
        raw_content,
        byte_offset: raw_content[0...match.begin(key)].bytesize,
        byte_length: match[key].bytesize
      )
      return if span.nil?

      [
        key,
        {
          source_field_path: "documents[0].fields.Items[#{item_index}]",
          provider_span_start: line_span[0] + span[:offset],
          provider_span_end: line_span[0] + span[:offset] + span[:length]
        }
      ]
    end

    {
      amount: amount.to_i.to_s,
      rate: rate_text,
      printed_total_stage: "after_item_discount",
      evidence: evidence
    }
  rescue ArgumentError, EncodingError, TypeError
    nil
  end

  def before_item_discount_evidence(analyze_result, items, item_index, detail)
    return unless detail[:amount_lines].one?
    return unless analyze_result["modelId"] == "prebuilt-receipt" && analyze_result["apiVersion"] == "2024-11-30"

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    content = analyze_result["content"]
    return unless mapper && content.is_a?(String) && mapper.length(content)

    item = items[item_index]
    parents = discount_parent_spans(item, content:, mapper:)
    return unless parents && parents.map { |start, finish| mapper.slice(content, offset: start, length: finish - start) }.join("\n") == item["content"]

    total = item.dig("valueObject", "TotalPrice")
    return unless total.is_a?(Hash) && total["content"].is_a?(String) && total["content"].valid_encoding?
    total_content = total["content"].unicode_normalize(:nfkc)
      .sub(profile.ocr_item_calculation_tax_marker_prefix_pattern, "")
      .sub(profile.ocr_item_calculation_tax_marker_suffix_pattern, "")
    return unless total_content.match?(ADJUSTMENT_AMOUNT_ONLY_PATTERN)
    return unless normalize_amount_for_discount(total_content) == detail[:original_line_total]

    total_span = exact_structured_authority_span(total, content:, mapper:)
    return unless total_span && parents.any? { |start, finish| total_span[0] >= start && total_span[1] <= finish }
    return unless items.each_with_index.all? do |other, index|
      next true if index == item_index

      other_parents = discount_parent_spans(other, content:, mapper:)
      other_parents && other_parents.none? { |other_parent| parents.any? { |parent| spans_overlap?(*parent, *other_parent) } }
    end

    pages = analyze_result["pages"]
    return unless pages.is_a?(Array) && pages.size <= MAX_REFERENCE_PRICING_TOTAL_PAGES

    page_lines = pages.filter_map do |page|
      lines = page.is_a?(Hash) ? page["lines"] : nil
      return unless lines.is_a?(Array) && lines.size <= MAX_REFERENCE_PRICING_TOTAL_LINES

      entries = lines.each_with_index.filter_map do |line, line_index|
        next unless line.is_a?(Hash)

        span = exact_structured_authority_span(line, content:, mapper:)
        next unless span && parents.any? { |start, finish| span[0] >= start && span[1] <= finish }

        { line: line, span: span, index: line_index }
      end
      [ page, entries ] unless entries.empty?
    end
    return unless page_lines.one?

    page, entries = page_lines.sole
    return unless entries.each_cons(2).all? { |left, right| left[:span][1] <= right[:span][0] }

    block = Ocr::ResponseParser::ItemCalculationDiscountBlock.call(lines: entries.map { |entry| entry[:line]["content"] }, profile:)
    return unless block && block[:rate] == detail[:rate] && block[:amount] == detail[:amount]

    block_entries = entries[block[:block_start_line_index]..block[:block_end_line_index]]
    return unless block_entries.first[:span][0] >= total_span[1]
    return unless discount_block_contiguous?(block_entries, page:, item:, parents:, content:, mapper:)

    evidence = block[:evidence].to_h do |key, component|
      entry = entries[component[:line_index]]
      span = mapper.span_for_bytes(
        entry[:line]["content"],
        byte_offset: component[:byte_offset],
        byte_length: component[:byte_length]
      )
      return unless span

      start = entry[:span][0] + span[:offset]
      return unless start >= total_span[1]

      [
        key,
        {
          source_field_path: "documents[0].fields.Items[#{item_index}]",
          provider_span_start: start,
          provider_span_end: start + span[:length]
        }
      ]
    end
    {
      amount: block[:amount].to_s,
      rate: block[:rate].to_s("F").sub(/0+\z/, "").sub(/\.\z/, ""),
      printed_total_stage: "before_item_discount",
      evidence: evidence
    }
  rescue ArgumentError, EncodingError, TypeError
    nil
  end

  def discount_block_contiguous?(entries, page:, item:, parents:, content:, mapper:)
    gaps = entries.each_cons(2).reject { |left, right| right[:index] == left[:index] + 1 }
    return true if gaps.empty?

    regions = item["boundingRegions"]
    return false unless regions.is_a?(Array) && regions.one? && regions.sole.is_a?(Hash)
    return false unless page["pageNumber"].is_a?(Integer) && page["pageNumber"].positive? && regions.sole["pageNumber"] == page["pageNumber"]

    parent_bounds = discount_polygon_bounds(regions.sole["polygon"], page:)
    return false unless parent_bounds

    words = page["words"]
    return false unless words.is_a?(Array) && words.size.between?(1, Ocr::ResponseParser::ItemCalculationModeLayoutExtractor::MAX_WORDS)

    word_entries = words.map do |word|
      return false unless word.is_a?(Hash)
      return false unless word["content"].is_a?(String) && word["content"].bytesize <= Ocr::ResponseParser::ItemCalculationModeLayoutExtractor::MAX_WORD_CONTENT_BYTES

      span = exact_structured_authority_span({ "content" => word["content"], "spans" => [ word["span"] ] }, content:, mapper:)
      return false unless span

      { span:, polygon: word["polygon"] }
    end
    return false unless word_entries.each_cons(2).all? { |left, right| left[:span][1] <= right[:span][0] }

    gaps.all? do |left, right|
      previous_end = left[:span][1]
      page["lines"][(left[:index] + 1)...right[:index]].all? do |line|
        next false unless line.is_a?(Hash)

        span = exact_structured_authority_span(line, content:, mapper:)
        next false unless span && span[0] >= previous_end && span[1] <= right[:span][0]
        next false if parents.any? { |parent| spans_overlap?(*span, *parent) }

        previous_end = span[1]
        discount_gap_line_outside_parent?(line, span:, word_entries:, parent_bounds:, page:, content:, mapper:)
      end
    end
  end

  def discount_gap_line_outside_parent?(line, span:, word_entries:, parent_bounds:, page:, content:, mapper:)
    bounds = discount_polygon_bounds(line["polygon"], page:)
    return false unless bounds

    side = if bounds[:right] < parent_bounds[:left]
      :left
    elsif bounds[:left] > parent_bounds[:right]
      :right
    end
    return false unless side

    index = word_entries.bsearch_index { |word| word[:span][1] > span[0] }
    return false unless index

    cursor = span[0]
    count = 0
    while index < word_entries.size && word_entries[index][:span][0] < span[1]
      word = word_entries[index]
      return false unless word[:span][0] >= cursor && word[:span][1] <= span[1]
      return false unless mapper.slice(content, offset: cursor, length: word[:span][0] - cursor)&.match?(/\A[ \t]*\z/)

      word_bounds = discount_polygon_bounds(word[:polygon], page:)
      return false unless word_bounds
      return false unless side == :left ? word_bounds[:right] < parent_bounds[:left] : word_bounds[:left] > parent_bounds[:right]

      cursor = word[:span][1]
      count += 1
      index += 1
    end
    count.positive? && mapper.slice(content, offset: cursor, length: span[1] - cursor)&.match?(/\A[ \t]*\z/)
  end

  def discount_polygon_bounds(polygon, page:)
    dimensions = [ page["width"], page["height"] ]
    maximum = Ocr::ResponseParser::ItemCalculationModeLayoutExtractor::MAX_PAGE_DIMENSION
    return unless dimensions.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? && value <= maximum }
    return unless polygon.is_a?(Array) && polygon.size == 8
    return unless polygon.all? { |value| value.is_a?(Numeric) && value.finite? }
    return unless polygon.each_slice(2).all? { |x, y| x.between?(0, dimensions[0]) && y.between?(0, dimensions[1]) }

    points = polygon.each_slice(2).map { |pair| pair.map { |value| Rational(value.to_s) } }
    crosses = 4.times.map do |index|
      first = points[index]
      second = points[(index + 1) % 4]
      third = points[(index + 2) % 4]
      (second[0] - first[0]) * (third[1] - second[1]) -
        (second[1] - first[1]) * (third[0] - second[0])
    end
    return unless crosses.all?(&:positive?) || crosses.all?(&:negative?)

    left, right = points.map(&:first).minmax
    { left:, right: }
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
    return true if normalized_line == normalized_label || normalized_label.start_with?("#{normalized_line} ")

    key = normalized_line.split(/[（(]/).first
    key.present? && key.length >= 2 && normalized_label.start_with?("#{key} ")
  end

  def match_item_index_from_line(line, item_labels, start_index)
    item_labels.each_with_index.drop(start_index).find do |label, _index|
      next false if label.blank?

      line == label || line.start_with?("#{label} ")
    end&.last
  end

  def item_discount_keyword_line?(line)
    return false if receipt_level_discount_line?(line)

    line.match?(profile.ocr_item_discount_line_pattern)
  end

  def receipt_level_discount_line?(line)
    line.match?(profile.ocr_receipt_level_discount_line_pattern)
  end

  def extract_discount_rate_from_line(line)
    rates = line.to_s.unicode_normalize(:nfkc).scan(/(\d+(?:\.\d+)?)\s*%/).flatten.uniq
    return nil unless rates.one?

    rate = BigDecimal(rates.sole) / 100
    rate if rate.between?(0, 1)
  end

  def extract_discount_amount_from_line(line)
    text = line.to_s.unicode_normalize(:nfkc).gsub(/\d+(?:\.\d+)?\s*%/, " ")
    return if text.include?("/")

    amounts = text.scan(/[-−▲]\s*[¥￥]?\s*(\d[\d,]*)(?![\d,.])/).flatten
    return unless amounts.one?

    ReceiptAmountService.parse_amount(amounts.sole)
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
    %i[@analyze_result @document @fields @raw_lines @normalized_lines @case_preserved_lines].each do |ivar|
      remove_instance_variable(ivar) if instance_variable_defined?(ivar)
    end
  end

  def text_cache_key(text)
    -text.to_s
  end
end
