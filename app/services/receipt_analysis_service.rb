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
      "[ReceiptAnalysis] unexpected_error receipt_id=#{receipt.id} error_class=#{e.class} error_code=unexpected_error"
    )
    fail_receipt!("unexpected_error", e.message)
    raise AnalysisError.new("unexpected_error", e.message)
  end

  private

  attr_reader :receipt

  def mark_processing!
    receipt.update!(
      status: "processing",
      processing_error_code: nil,
      processing_error_message: nil,
      review_reasons: []
    )
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
    ai_result = ReceiptAiEnrichmentService.call(
      ocr_result,
      ai_name_completion_enabled: ai_name_completion_enabled?
    )
    normalized = normalize_ai_result(ai_result)

    Rails.logger.info(
      "[ReceiptAnalysis] ai_result receipt_id=#{receipt.id} success=#{normalized[:success]} error_code=#{normalized[:error_code]}"
    )

    normalized
    # rescue ReceiptAiEnrichmentService::AiEnrichmentError => e
    #   Rails.logger.warn(
    #     "[ReceiptAnalysis] ai_failed_fallback receipt_id=#{receipt.id} error_code=#{e.error_code} message=#{e.message}"
    #   )
    #   { success: false, error_code: e.error_code }
    # end
    #
    # ReceiptAiEnrichmentService は現在、例外をそのまま上げず ResultTemplate.error を返す設計へ寄せている。
    # そのためこの rescue は現状ほぼ通らないが、直前の挙動との差分確認用に一旦コメントで残す。
  end

  # 商品名AI補完
  def ai_name_completion_enabled?
    receipt.user&.product_name_ai_completion_enabled == true
  end

  def normalize_ai_result(result)
    # NOTE:
    # AI 共通の item 正規化は Analysis::ReceiptItemNormalizer に寄せ、
    # ReceiptAnalysisService では success / error の判定と全体フロー制御を主責務とする。

    return { success: false, error_code: "ai_invalid_response" } unless result.is_a?(Hash)

    symbolized = result.symbolize_keys

    if symbolized[:success] == false
      return {
        success: false,
        error_code: symbolized[:error_code].presence || "ai_invalid_response"
      }
    end

    # success系は receipt_attributes を含む構造のみ受け付ける
    unless symbolized[:receipt_attributes].is_a?(Hash)
      return { success: false, error_code: "ai_invalid_response" }
    end

    # receipt_items_attributes が無い場合は空配列で扱う
    symbolized[:receipt_items_attributes] ||= []

    {
      success: symbolized.key?(:success) ? symbolized[:success] : true,
      error_code: symbolized[:error_code],
      needs_review: symbolized[:needs_review],
      review_reasons: Array(symbolized[:review_reasons]),
      receipt_attributes: symbolized[:receipt_attributes].symbolize_keys,
      receipt_items_attributes: Analysis::ReceiptItemNormalizer.normalize_ai_items(
        symbolized[:receipt_items_attributes]
      )
    }
  end

  def unreadable_ocr?(ocr_result)
    candidates = ocr_candidates(ocr_result)
    raw_text = ocr_result[:raw_text].to_s
    items = Array(candidates[:items])
    overall_confidence = candidates.dig(:confidence_summary, :overall)
    # TODO: 実レスポンスで confidence_summary の配置を再確認する。
    # 現在は candidates 配下を参照しているが、meta 配下に入る可能性もあるため、
    # API実レスポンス確認後に参照先を一本化する。

    return true if raw_text.blank?
    return true if items.blank? && candidates[:store_name].blank? && candidates[:total_amount].blank?
    return true if overall_confidence.present? && overall_confidence.to_f < UNREADABLE_CONFIDENCE_THRESHOLD

    false
  end

  def low_quality_ocr?(ocr_result, receipt_attributes:)
    candidates = ocr_candidates(ocr_result)
    items = Array(candidates[:items])
    items_average = candidates.dig(:confidence_summary, :items_average)
    # TODO: 実レスポンスで confidence_summary の配置を再確認する。
    # unreadable_ocr? と同様に、candidates / meta のどちらが正なのか確認後に整理する。

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
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: ai_result)

    # === AmountService integration ===
    amount_result = ReceiptAmountService.call(
      receipt: params[:receipt_attributes],
      receipt_items: params[:receipt_items_attributes],
      receipt_tax_details: params[:receipt_tax_details_attributes],
      context: :analysis
    )

    # 金額を補正（resolvedを採用）
    params[:receipt_attributes].merge!(
      total_amount: amount_result[:resolved][:total],
      subtotal_amount: amount_result[:resolved][:subtotal],
      tax_amount: amount_result[:resolved][:tax],
      tax_rate: amount_result[:resolved][:tax_rate]
    )

    # TODO: 次回、AmountService経由で受け取れる mismatch_codes / mismatch_messages を flash 表示へ接続する。
    # AnalysisService から Amounts::MismatchCodes は直接呼ばず、表示用情報も ReceiptAmountService の返却値を使う。
    review_reasons = merge_review_reasons(
      ai_result[:review_reasons],
      amount_result[:inconsistencies]
    )

    final_status = determine_final_status(
      ocr_result: ocr_result,
      receipt_attributes: params[:receipt_attributes],
      items_attributes: params[:receipt_items_attributes],
      ai_needs_review: ai_result[:needs_review],
      amount_needs_review: amount_result[:needs_review]
    )

    persist_result_full!(
      receipt_attributes: params[:receipt_attributes].merge(
        status: final_status,
        processing_error_code: nil,
        processing_error_message: nil,
        review_reasons: review_reasons,
        ocr_completed_at: Time.current
      ),
      items_attributes: params[:receipt_items_attributes],
      payments_attributes: params[:receipt_payments_attributes],
      tax_details_attributes: amount_result[:tax_details]
    )

    Rails.logger.info(
      "[ReceiptAnalysis] completed receipt_id=#{receipt.id} status=#{final_status} items=#{params[:receipt_items_attributes].size}"
    )

    receipt
  end

  def save_ocr_only_result!(ocr_result)
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)

    # === AmountService integration point (OCR only) ===
    amount_result = ReceiptAmountService.call(
      receipt: params[:receipt_attributes],
      receipt_items: params[:receipt_items_attributes],
      receipt_tax_details: params[:receipt_tax_details_attributes],
      context: :analysis
    )

    params[:receipt_attributes].merge!(
      total_amount: amount_result[:resolved][:total],
      subtotal_amount: amount_result[:resolved][:subtotal],
      tax_amount: amount_result[:resolved][:tax],
      tax_rate: amount_result[:resolved][:tax_rate]
    )

    items_attributes = apply_ocr_only_tax_rate_policy(
      params[:receipt_items_attributes],
      amount_result
    )

    # TODO: 次回、AmountService経由で受け取れる mismatch_codes / mismatch_messages を flash 表示へ接続する。
    # AnalysisService から Amounts::MismatchCodes は直接呼ばず、表示用情報も ReceiptAmountService の返却値を使う。
    review_reasons = merge_review_reasons([], amount_result[:inconsistencies])

    # 仕様上、AI無効時の OCR only 保存ルートは completed ではなく review_needed を基本にする。
    # 先に AI クライアント層と通常 AI 保存ルートの安定化を優先するため、ここでは固定にしておく。
    final_status = "review_needed"

    persist_result_full!(
      receipt_attributes: params[:receipt_attributes].merge(
        status: final_status,
        processing_error_code: nil,
        processing_error_message: nil,
        review_reasons: review_reasons,
        ocr_completed_at: Time.current
      ),
      items_attributes: items_attributes,
      payments_attributes: params[:receipt_payments_attributes],
      tax_details_attributes: amount_result[:tax_details]
    )

    Rails.logger.info(
      "[ReceiptAnalysis] ocr_only_completed receipt_id=#{receipt.id} status=#{final_status} items=#{items_attributes.size}"
    )

    receipt
  end

  def save_fallback_result!(ocr_result, error_code)
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)

    # === AmountService integration point (fallback) ===
    amount_result = ReceiptAmountService.call(
      receipt: params[:receipt_attributes],
      receipt_items: params[:receipt_items_attributes],
      receipt_tax_details: params[:receipt_tax_details_attributes],
      context: :analysis
    )

    params[:receipt_attributes].merge!(
      total_amount: amount_result[:resolved][:total],
      subtotal_amount: amount_result[:resolved][:subtotal],
      tax_amount: amount_result[:resolved][:tax],
      tax_rate: amount_result[:resolved][:tax_rate]
    )

    items_attributes = apply_ocr_only_tax_rate_policy(
      params[:receipt_items_attributes],
      amount_result
    )

    # TODO: 次回、AmountService経由で受け取れる mismatch_codes / mismatch_messages を flash 表示へ接続する。
    # AnalysisService から Amounts::MismatchCodes は直接呼ばず、表示用情報も ReceiptAmountService の返却値を使う。
    review_reasons = merge_review_reasons([], amount_result[:inconsistencies])

    # NOTE:
    # fallback 保存時は processing_error_code に AI 側の内部コードをそのまま保持している。
    # fail_receipt! は mapper を通しているため扱いが完全一致していないが、
    # 先に AI 通信と保存フローの安定化を優先し、コード統一は後続で整理する。
    receipt_attributes = params[:receipt_attributes].merge(
      status: "review_needed",
      processing_error_code: error_code,
      processing_error_message: nil,
      review_reasons: review_reasons,
      ocr_completed_at: Time.current
    )

    persist_result_full!(
      receipt_attributes: receipt_attributes,
      items_attributes: items_attributes,
      payments_attributes: params[:receipt_payments_attributes],
      tax_details_attributes: amount_result[:tax_details]
    )

    Rails.logger.warn(
      "[ReceiptAnalysis] fallback_saved receipt_id=#{receipt.id} error_code=#{error_code} items=#{items_attributes.size}"
    )

    receipt
  end

  def fail_receipt!(error_code, message = nil)
    mapped = Analysis::ReceiptProcessingErrorMapper.map(error_code)

    receipt.update!(
      status: "failed",
      processing_error_code: mapped[:error_code],
      processing_error_message: message,
      review_reasons: [],
      ocr_completed_at: Time.current
    )

    Rails.logger.error(
      "[ReceiptAnalysis] failed receipt_id=#{receipt.id} error_code=#{error_code}"
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

    # item-level needs_review は ReceiptBuildParamsService で最終決定済みの前提。
    # ReceiptAnalysisService では保存用の整形に留め、true/false の再判定は行わない。
    normalize_items_attributes(items_attributes).each_with_index do |item_attributes, index|
      receipt.receipt_items.create!(
        item_attributes.merge(position_index: item_attributes[:position_index] || index + 1)
      )
    end
  end

  def determine_final_status(ocr_result:, receipt_attributes:, items_attributes:, ai_needs_review: nil, amount_needs_review: nil)
    return "review_needed" if amount_needs_review
    return "review_needed" if ai_needs_review
    return "review_needed" if low_quality_ocr?(ocr_result, receipt_attributes: receipt_attributes)
    return "review_needed" if receipt_attributes[:store_name].blank?
    return "review_needed" if receipt_attributes[:total_amount].blank?
    return "review_needed" if receipt_attributes[:payment_method].blank?
    return "review_needed" if items_attributes.blank?
    # receipt 全体の status 判定はこのサービスで行うが、item-level needs_review 自体は前段の値を参照する。
    return "review_needed" if items_attributes.any? { |item| item_needs_review?(item) }

    "completed"
  end

  def merge_review_reasons(*reason_groups)
    reason_groups
      .flatten
      .compact
      .map(&:to_s)
      .reject(&:blank?)
      .uniq
  end

  # ReceiptBuildParamsService が save-ready な item 値を返す前提で、
  # この層では型の最小調整と position_index 補完のみ行う。
  def normalize_items_attributes(items)
    Array(items).map.with_index do |item, index|
      symbolized = if item.respond_to?(:with_indifferent_access)
        item.with_indifferent_access
      elsif item.respond_to?(:symbolize_keys)
        item.symbolize_keys.with_indifferent_access
      else
        {}.with_indifferent_access
      end

      {
        raw_text: symbolized[:raw_text].to_s,
        suggested_name: symbolized[:suggested_name].presence,
        confirmed_name: symbolized[:confirmed_name].presence,
        category: symbolized[:category].presence,
        price: normalize_amount(symbolized[:price]),
        quantity: normalize_quantity(symbolized[:quantity]),
        quantity_unit: symbolized[:quantity_unit].presence,
        product_code: symbolized[:product_code].presence,
        tax_rate: normalize_tax_rate(symbolized[:tax_rate]),
        original_line_total: normalize_amount(symbolized[:original_line_total]),
        line_total: normalize_amount(symbolized[:line_total]),
        discount_amount: normalize_amount(symbolized[:discount_amount]),
        discount_rate: normalize_tax_rate(symbolized[:discount_rate]),
        # item-level needs_review は前段で決めた値を保持し、この層では再判定しない。
        needs_review: symbolized[:needs_review],
        position_index: symbolized[:position_index] || index + 1,
        confidence: normalize_confidence(symbolized[:confidence])
      }
    end
  end

  def ocr_candidates(ocr_result)
    (ocr_result[:candidates] || {}).deep_symbolize_keys
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

  def normalize_tax_rate(value)
    return nil if value.blank?

    tax_rate = BigDecimal(value.to_s.delete("%"))
    tax_rate > 1 ? tax_rate / 100 : tax_rate
  rescue ArgumentError
    nil
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

  def apply_ocr_only_tax_rate_policy(items_attributes, amount_result)
    resolved_tax_rate = amount_result.dig(:resolved, :tax_rate)

    Array(items_attributes).map do |item_attributes|
      normalized_item = if item_attributes.respond_to?(:with_indifferent_access)
        item_attributes.with_indifferent_access
      elsif item_attributes.respond_to?(:symbolize_keys)
        item_attributes.symbolize_keys.with_indifferent_access
      else
        {}.with_indifferent_access
      end

      # AIを使えないルートでは、複数税率の明細別割り当ては行わない。
      # 単一税率のみ、OCR値またはAmountService推定値を全明細へ反映する。
      normalized_item[:tax_rate] = resolved_tax_rate.present? ? resolved_tax_rate : nil
      normalized_item.to_h.symbolize_keys
    end
  end

  def detect_category(text)
    Analysis::ReceiptFallbackPatterns.detect_category(text)
  end
end
