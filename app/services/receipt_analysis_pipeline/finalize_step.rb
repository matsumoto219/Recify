class ReceiptAnalysisPipeline
  class FinalizeStep
    REVIEW_NEEDED_CONFIDENCE_THRESHOLD = Config::REVIEW_NEEDED_CONFIDENCE_THRESHOLD

    def self.call(receipt:, decision:, run: nil)
      new(receipt: receipt, decision: decision, run: run).call
    end

    def initialize(receipt:, decision:, run: nil)
      @receipt = receipt
      @decision = decision
      @run = run
    end

    def call
      case decision.finalize_strategy
      when "fail_receipt"
        fail_receipt!(
          decision.error_code,
          decision.error_message,
          decision.receipt_attributes
        )
      when "ocr_only"
        save_ocr_only_result!(ocr_result_for_finalize)
      when "ai_fallback"
        save_fallback_result!(
          ocr_result_for_finalize,
          decision.error_code,
          processing_error_message: decision.error_message
        )
      when "ai_success"
        save_ai_result!(ocr_result_for_finalize, ai_result_for_finalize)
      else
        raise ReceiptAnalysisPipeline::AnalysisError.new(
          "unexpected_error",
          "Unknown finalize_strategy=#{decision.finalize_strategy}"
        )
      end
    end

    private

    attr_reader :receipt, :decision, :run

    def ocr_result_for_finalize
      return decision.ocr_result if decision.ocr_result.present?

      rehydrate_ocr_snapshot(run&.ocr_result_snapshot)
    end

    def ai_result_for_finalize
      return decision.ai_result if decision.ai_result.present?

      rehydrate_ai_snapshot(run&.ai_normalized_result_snapshot)
    end

    def rehydrate_ocr_snapshot(snapshot)
      snapshot = normalized_hash(snapshot)
      return nil if snapshot.blank?

      {
        success: snapshot[:success] == true,
        lines: Array(snapshot[:lines]).map(&:to_s),
        candidates: normalized_hash(snapshot[:candidates]).to_h,
        error_code: snapshot[:error_code].presence,
        meta: normalized_hash(snapshot[:meta]).to_h
      }.compact
    end

    def rehydrate_ai_snapshot(snapshot)
      snapshot = normalized_hash(snapshot)
      return nil if snapshot.blank?

      {
        success: snapshot[:success] == true,
        error_code: snapshot[:error_code].presence,
        needs_review: snapshot[:needs_review] == true,
        review_reasons: Array(snapshot[:review_reasons]),
        receipt_attributes: rehydrate_ai_receipt_attributes(snapshot[:receipt_attributes]),
        receipt_items_attributes: rehydrate_ai_items(snapshot[:receipt_items_attributes]),
        receipt_adjustments_attributes: rehydrate_ai_adjustments(snapshot[:receipt_adjustments_attributes]),
        meta: normalized_hash(snapshot[:meta]).to_h
      }.compact
    end

    def rehydrate_ai_receipt_attributes(value)
      attributes = normalized_hash(value).to_h

      %i[purchased_at ocr_completed_at].each do |key|
        attributes[key] = parse_time_value(attributes[key]) if attributes[key].present?
      end

      attributes
    end

    def rehydrate_ai_items(value)
      Array(value).map do |item|
        normalized_hash(item).to_h
      end
    end

    def rehydrate_ai_adjustments(value)
      Array(value).map do |adjustment|
        normalized_hash(adjustment).to_h
      end
    end

    def parse_time_value(value)
      return value unless value.is_a?(String)

      Time.zone.parse(value)
    rescue ArgumentError, TypeError
      value
    end

    def save_ai_result!(ocr_result, ai_result)
      params = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: ai_result)
      record_build_params_snapshot(params)

      # === AmountService integration ===
      amount_result = ReceiptAmountService.call(
        receipt: params[:receipt_attributes],
        receipt_items: params[:receipt_items_attributes],
        receipt_tax_details: params[:receipt_tax_details_attributes],
        receipt_adjustments: params[:receipt_adjustments_attributes],
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
      ocr_low_quality = low_quality_ocr?(ocr_result, receipt_attributes: params[:receipt_attributes])
      ocr_review_reasons = ocr_review_reasons_for(ocr_result)
      if ocr_low_quality
        ocr_review_reasons << "ocr_low_confidence"
      end

      review_reasons = merge_review_reasons(
        ai_result[:review_reasons],
        params[:review_reasons],
        amount_review_reasons(amount_result),
        ocr_review_reasons
      )

      final_status = determine_final_status(
        ocr_result: ocr_result,
        receipt_attributes: params[:receipt_attributes],
        items_attributes: params[:receipt_items_attributes],
        ai_needs_review: ai_result[:needs_review],
        amount_needs_review: amount_result[:needs_review],
        build_review_reasons: params[:review_reasons],
        ocr_review_reasons: ocr_review_reasons,
        ocr_low_quality: ocr_low_quality
      )
      items_attributes = apply_amount_item_totals(
        params[:receipt_items_attributes],
        amount_result.dig(:computed, :items)
      )

      persist_result_full!(
        receipt_attributes: params[:receipt_attributes].merge(
          status: final_status,
          processing_error_code: nil,
          processing_error_message: nil,
          review_reasons: review_reasons,
          ocr_completed_at: Time.current,
          amount_calculation_profile: amount_calculation_profile_snapshot(amount_result, tax_rate_correction: params[:tax_rate_correction])
        ),
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: amount_result[:tax_details],
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      Rails.logger.info(
        "[ReceiptAnalysis] completed receipt_id=#{receipt.id} status=#{final_status} items=#{items_attributes.size}"
      )

      receipt
    end

    def save_ocr_only_result!(ocr_result)
      params = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: nil)
      record_build_params_snapshot(params)

      # === AmountService integration point (OCR only) ===
      amount_result = ReceiptAmountService.call(
        receipt: params[:receipt_attributes],
        receipt_items: params[:receipt_items_attributes],
        receipt_tax_details: params[:receipt_tax_details_attributes],
        receipt_adjustments: params[:receipt_adjustments_attributes],
        context: :analysis
      )

      params[:receipt_attributes].merge!(
        total_amount: amount_result[:resolved][:total],
        subtotal_amount: amount_result[:resolved][:subtotal],
        tax_amount: amount_result[:resolved][:tax],
        tax_rate: amount_result[:resolved][:tax_rate]
      )

      items_attributes = apply_amount_item_totals(
        apply_ocr_only_tax_rate_policy(params[:receipt_items_attributes], amount_result),
        amount_result.dig(:computed, :items)
      )

      # TODO: 次回、AmountService経由で受け取れる mismatch_codes / mismatch_messages を flash 表示へ接続する。
      # AnalysisService から Amounts::MismatchCodes は直接呼ばず、表示用情報も ReceiptAmountService の返却値を使う。
      ocr_review_reasons = ocr_review_reasons_for(ocr_result)
      if low_quality_ocr?(ocr_result, receipt_attributes: params[:receipt_attributes])
        ocr_review_reasons << "ocr_low_confidence"
      end

      review_reasons = merge_review_reasons(params[:review_reasons], amount_review_reasons(amount_result), ocr_review_reasons)

      # 仕様上、AI無効時の OCR only 保存ルートは completed ではなく review_needed を基本にする。
      # 先に AI クライアント層と通常 AI 保存ルートの安定化を優先するため、ここでは固定にしておく。
      final_status = "review_needed"

      persist_result_full!(
        receipt_attributes: params[:receipt_attributes].merge(
          status: final_status,
          processing_error_code: nil,
          processing_error_message: nil,
          review_reasons: review_reasons,
          ocr_completed_at: Time.current,
          amount_calculation_profile: amount_calculation_profile_snapshot(amount_result, tax_rate_correction: params[:tax_rate_correction])
        ),
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: amount_result[:tax_details],
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      Rails.logger.info(
        "[ReceiptAnalysis] ocr_only_completed receipt_id=#{receipt.id} status=#{final_status} items=#{items_attributes.size}"
      )

      receipt
    end

    def save_fallback_result!(ocr_result, error_code, processing_error_message: nil)
      params = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: nil)
      record_build_params_snapshot(params)

      # === AmountService integration point (fallback) ===
      amount_result = ReceiptAmountService.call(
        receipt: params[:receipt_attributes],
        receipt_items: params[:receipt_items_attributes],
        receipt_tax_details: params[:receipt_tax_details_attributes],
        receipt_adjustments: params[:receipt_adjustments_attributes],
        context: :analysis
      )

      params[:receipt_attributes].merge!(
        total_amount: amount_result[:resolved][:total],
        subtotal_amount: amount_result[:resolved][:subtotal],
        tax_amount: amount_result[:resolved][:tax],
        tax_rate: amount_result[:resolved][:tax_rate]
      )

      items_attributes = apply_amount_item_totals(
        apply_ocr_only_tax_rate_policy(params[:receipt_items_attributes], amount_result),
        amount_result.dig(:computed, :items)
      )

      # TODO: 次回、AmountService経由で受け取れる mismatch_codes / mismatch_messages を flash 表示へ接続する。
      # AnalysisService から Amounts::MismatchCodes は直接呼ばず、表示用情報も ReceiptAmountService の返却値を使う。
      ocr_review_reasons = ocr_review_reasons_for(ocr_result)
      if low_quality_ocr?(ocr_result, receipt_attributes: params[:receipt_attributes])
        ocr_review_reasons << "ocr_low_confidence"
      end

      review_reasons = merge_review_reasons(params[:review_reasons], amount_review_reasons(amount_result), ocr_review_reasons)

      # NOTE:
      # fallback 保存時は processing_error_code に AI 側の内部コードをそのまま保持している。
      # fail_receipt! は mapper を通しているため扱いが完全一致していないが、
      # 先に AI 通信と保存フローの安定化を優先し、コード統一は後続で整理する。
      receipt_attributes = params[:receipt_attributes].merge(
        status: "review_needed",
        processing_error_code: error_code,
        processing_error_message: processing_error_message,
        review_reasons: review_reasons,
        ocr_completed_at: Time.current,
        amount_calculation_profile: amount_calculation_profile_snapshot(amount_result, tax_rate_correction: params[:tax_rate_correction])
      )

      persist_result_full!(
        receipt_attributes: receipt_attributes,
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: amount_result[:tax_details],
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      Rails.logger.warn(
        "[ReceiptAnalysis] fallback_saved receipt_id=#{receipt.id} error_code=#{error_code} items=#{items_attributes.size}"
      )

      receipt
    end

    def fail_receipt!(error_code, message = nil, attributes = {})
      mapped = Analysis.processing_error_mapping(error_code)
      receipt_attributes = {
        status: "failed",
        processing_error_code: mapped[:error_code],
        processing_error_message: message,
        review_reasons: [],
        ocr_completed_at: Time.current
      }.merge(attributes)

      receipt.update!(receipt_attributes)

      Rails.logger.error(
        "[ReceiptAnalysis] failed receipt_id=#{receipt.id} error_code=#{error_code}"
      )

      receipt
    end

    def persist_result_full!(receipt_attributes:, items_attributes:, payments_attributes:, tax_details_attributes:, adjustments_attributes: [])
      Receipt.transaction do
        receipt.update!(receipt_attributes)

        replace_receipt_items!(items_attributes)
        replace_receipt_adjustments!(adjustments_attributes)

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
      # FinalizeStep では保存用の整形に留め、true/false の再判定は行わない。
      normalize_items_attributes(items_attributes).each_with_index do |item_attributes, index|
        receipt.receipt_items.create!(
          item_attributes.merge(position_index: item_attributes[:position_index] || index + 1)
        )
      end
    end

    def replace_receipt_adjustments!(adjustments_attributes)
      receipt.receipt_adjustments.destroy_all

      normalize_adjustments_attributes(adjustments_attributes).each_with_index do |adjustment_attributes, index|
        receipt.receipt_adjustments.create!(
          adjustment_attributes.merge(position_index: adjustment_attributes[:position_index] || index + 1)
        )
      end
    end

    def apply_amount_item_totals(items_attributes, calculated_items)
      calculated_items = Array(calculated_items)
      return items_attributes if calculated_items.empty?

      Array(items_attributes).map.with_index do |item_attributes, index|
        calculated_item = calculated_items[index]
        next item_attributes if calculated_item.blank?

        item_attributes.merge(
          price: safe_calculated_amount(calculated_item[:price] || calculated_item["price"]) || item_attributes[:price],
          quantity: calculated_item[:quantity] || calculated_item["quantity"],
          original_line_total: safe_calculated_amount(calculated_item[:original_line_total] || calculated_item["original_line_total"]) || item_attributes[:original_line_total],
          line_total: safe_calculated_amount(calculated_item[:line_total] || calculated_item["line_total"]) || item_attributes[:line_total],
          discount_amount: safe_calculated_amount(calculated_item[:discount_amount] || calculated_item["discount_amount"]) || item_attributes[:discount_amount],
          discount_rate: calculated_item[:discount_rate] || calculated_item["discount_rate"]
        )
      end
    end

    def determine_final_status(ocr_result:, receipt_attributes:, items_attributes:, ai_needs_review: nil, amount_needs_review: nil, build_review_reasons: [], ocr_review_reasons: [], ocr_low_quality: nil)
      return "review_needed" if amount_needs_review
      return "review_needed" if ai_needs_review
      return "review_needed" if ReviewReasonSource.blocking_reasons_for_user(build_review_reasons).any?
      return "review_needed" if ReviewReasonSource.blocking_reasons_for_user(ocr_review_reasons).any?
      ocr_low_quality = low_quality_ocr?(ocr_result, receipt_attributes: receipt_attributes) if ocr_low_quality.nil?
      return "review_needed" if ocr_low_quality
      return "review_needed" if receipt_attributes[:store_name].blank?
      return "review_needed" if receipt_attributes[:total_amount].blank?
      return "review_needed" if receipt_attributes[:payment_method].blank?
      return "review_needed" if items_attributes.blank?
      # receipt 全体の status 判定はこのstepで行うが、item-level needs_review 自体は前段の値を参照する。
      return "review_needed" if items_attributes.any? { |item| item_needs_review?(item) }

      "completed"
    end

    def merge_review_reasons(*reason_groups)
      ReviewReasonSource.review_reasons_for_user(
        reason_groups
        .flatten
        .compact
        .map(&:to_s)
        .reject(&:blank?)
        .uniq
      )
    end

    def amount_review_reasons(amount_result)
      if amount_result.key?(:blocking_inconsistencies)
        Array(amount_result[:blocking_inconsistencies]).uniq
      else
        Array(amount_result[:inconsistencies])
      end
    end

    def ocr_review_reasons_for(ocr_result)
      candidates = ocr_candidates(ocr_result)
      ReviewReasonSource.review_reasons_for_user(candidates[:review_reasons])
    end

    def amount_calculation_profile_snapshot(amount_result, tax_rate_correction: nil)
      snapshot = ReceiptAmountService.calculation_profile_snapshot(amount_result)
      return snapshot if tax_rate_correction.blank?

      snapshot[:profile] ||= {}
      snapshot[:profile][:tax_rate_correction] = tax_rate_correction
      snapshot
    end

    def record_build_params_snapshot(params)
      return if run.blank?

      ReceiptAnalysisRuns.record_build_params_snapshot(run, params)
    end

    def normalize_items_attributes(items)
      Array(items).filter_map.with_index do |item, index|
        symbolized = if item.respond_to?(:with_indifferent_access)
          item.with_indifferent_access
        elsif item.respond_to?(:symbolize_keys)
          item.symbolize_keys.with_indifferent_access
        else
          {}.with_indifferent_access
        end

        price = normalize_amount(symbolized[:price])
        original_line_total = normalize_amount(symbolized[:original_line_total])
        line_total = normalize_amount(symbolized[:line_total])
        discount_amount = normalize_amount(symbolized[:discount_amount])
        next if [ price, original_line_total, line_total, discount_amount ].compact.any?(&:negative?)

        {
          raw_text: symbolized[:raw_text].to_s,
          suggested_name: symbolized[:suggested_name].presence,
          confirmed_name: symbolized[:confirmed_name].presence,
          category: symbolized[:category].presence,
          price: price,
          quantity: normalize_quantity(symbolized[:quantity]),
          quantity_unit: symbolized[:quantity_unit].presence,
          product_code: symbolized[:product_code].presence,
          tax_rate: normalize_tax_rate(symbolized[:tax_rate]),
          original_line_total: original_line_total,
          line_total: line_total,
          discount_amount: discount_amount,
          discount_rate: normalize_tax_rate(symbolized[:discount_rate]),
          # item-level needs_review は前段で決めた値を保持し、この層では再判定しない。
          needs_review: symbolized[:needs_review],
          review_reasons: normalize_review_reasons(symbolized[:review_reasons]),
          position_index: symbolized[:position_index] || index + 1,
          confidence: normalize_confidence(symbolized[:confidence])
        }
      end
    end

    def normalize_adjustments_attributes(adjustments)
      Array(adjustments).filter_map.with_index do |adjustment, index|
        symbolized = if adjustment.respond_to?(:with_indifferent_access)
          adjustment.with_indifferent_access
        elsif adjustment.respond_to?(:symbolize_keys)
          adjustment.symbolize_keys.with_indifferent_access
        else
          {}.with_indifferent_access
        end

        amount = normalize_amount(symbolized[:amount])
        next unless amount&.positive?

        kind = symbolized[:kind].to_s
        sign = symbolized[:sign].to_s
        source = symbolized[:source].to_s.presence || "ai"

        {
          kind: ReceiptAdjustment::KINDS.include?(kind) ? kind : "other",
          label: symbolized[:label].to_s.strip.presence,
          amount: amount.abs,
          sign: ReceiptAdjustment::SIGNS.include?(sign) ? sign : "discount",
          tax_rate: normalize_tax_rate(symbolized[:tax_rate]),
          source: ReceiptAdjustment::SOURCES.include?(source) ? source : "ai",
          source_text: symbolized[:source_text].to_s.strip.presence,
          source_line_index: symbolized[:source_line_index],
          confidence: normalize_confidence(symbolized[:confidence]),
          needs_review: symbolized[:needs_review] == true,
          review_reasons: normalize_review_reasons(symbolized[:review_reasons]),
          position_index: symbolized[:position_index] || index + 1
        }.compact
      end
    end

    def normalize_review_reasons(value)
      Array(value).filter_map do |reason|
        normalized = reason.to_s.strip
        normalized.presence
      end.uniq
    end

    def normalize_amount(value)
      ReceiptAmountService.parse_amount_or_nil(value)
    end

    def safe_calculated_amount(value)
      amount = normalize_amount(value)
      amount&.negative? ? nil : amount
    end

    def normalize_quantity(value)
      quantity = ReceiptAmountService.parse_quantity(value, default: BigDecimal("1"))

      quantity.positive? ? quantity : BigDecimal("1")
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
      Analysis.detect_category(text)
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

    def ocr_candidates(ocr_result)
      (ocr_result[:candidates] || {}).deep_symbolize_keys
    end

    def normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

      {}.with_indifferent_access
    end
  end
end
