class ReceiptAnalysisPipeline
  class FinalizeStep
    REVIEW_NEEDED_CONFIDENCE_THRESHOLD = Config::REVIEW_NEEDED_CONFIDENCE_THRESHOLD
    ITEM_TOTAL_DRIFT_REVIEW_REASON = "item_total_mismatch"
    ITEM_TOTAL_DRIFT_ABSOLUTE_THRESHOLD = 100
    ITEM_TOTAL_DRIFT_RELATIVE_THRESHOLD = BigDecimal("0.01")
    ITEM_TOTAL_DRIFT_SELECTED_BASES = %w[
      printed_tax_details_net
      printed_tax_details_gross
      external_tax_from_receipt
    ].freeze
    ITEM_TOTAL_DRIFT_SUPPRESSION_REASONS = %w[
      adjustment_uncertain
      discount_data_incomplete
      price_tax_inclusion_uncertain
    ].freeze
    ADJUSTMENT_UNCERTAIN_REVIEW_REASON = "adjustment_uncertain"
    PURCHASED_AT_CONFLICTED_REVIEW_REASON = "purchased_at_conflicted"
    ITEM_NAME_UNCERTAIN_REVIEW_REASON = "item_name_uncertain"
    ITEMS_MISSING_REVIEW_REASON = "items_missing"
    ITEM_TAX_RATE_UNCERTAIN_REVIEW_REASON = "item_tax_rate_uncertain"
    ITEM_TAX_RATE_RESOLUTION_BLOCKING_REASONS = %w[
      item_total_mismatch
      tax_amount_mismatch
      tax_detail_mismatch
      item_tax_rate_group_uncertain
    ].freeze
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
        case_preserved_lines: Array(snapshot[:case_preserved_lines]).map(&:to_s),
        candidates: normalized_hash(snapshot[:candidates]).to_h,
        candidate_counts: normalized_hash(snapshot[:candidate_counts]).to_h,
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
        attribute_counts: normalized_hash(snapshot[:attribute_counts]).to_h,
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
      validate_source_structural_limits!(ocr_result: ocr_result, ai_result: ai_result)
      params = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: ai_result)
      params = Analysis.enforce_ownership_consistency(params: params)
      record_build_params_snapshot(params)
      validate_structural_limits!(params)

      # === AmountService integration ===
      amount_result = ReceiptAmountService.call(
        receipt: params[:receipt_attributes],
        receipt_items: params[:receipt_items_attributes],
        receipt_tax_details: params[:receipt_tax_details_attributes],
        receipt_adjustments: params[:receipt_adjustments_attributes],
        receipt_payments: params[:receipt_payments_attributes],
        context: :analysis
      )
      amount_result = amount_result_with_receipt_amount_overrides(params, amount_result)

      # 金額を補正（通常はresolvedを採用。預り差額から復元したtotalだけは支払一致時に保護する）
      params[:receipt_attributes].merge!(receipt_amount_attributes_for(params, amount_result))
      params[:receipt_items_attributes] = clear_resolved_item_review_flags(params[:receipt_items_attributes])

      ocr_low_quality = low_quality_ocr?(ocr_result, receipt_attributes: params[:receipt_attributes])
      ocr_review_reasons = ocr_review_reasons_for(ocr_result)
      if ocr_low_quality
        ocr_review_reasons << "ocr_low_confidence"
      end

      ai_review_reasons = resolved_ai_review_reasons(ai_result, params, amount_result, ocr_result:)
      ai_needs_review = ai_result[:needs_review] == true && ai_review_reasons.any?
      item_drift_review_reasons = item_total_drift_review_reasons(params, amount_result, ai_result:)
      detail_reasons = detail_review_reasons_for(params)

      review_reasons = merge_review_reasons(
        ai_review_reasons,
        params[:review_reasons],
        missing_core_review_reasons(params[:receipt_attributes]),
        detail_reasons,
        item_drift_review_reasons,
        amount_review_reasons(amount_result),
        ocr_review_reasons
      )

      final_status = determine_final_status(
        ocr_result: ocr_result,
        receipt_attributes: params[:receipt_attributes],
        items_attributes: params[:receipt_items_attributes],
        ai_needs_review: ai_needs_review,
        amount_needs_review: amount_result[:needs_review],
        build_review_reasons: review_reasons,
        ocr_review_reasons: ocr_review_reasons,
        detail_needs_review: detail_needs_review?(params),
        ocr_low_quality: ocr_low_quality
      )
      items_attributes = apply_amount_item_totals(
        params[:receipt_items_attributes],
        amount_result.dig(:computed, :items)
      )
      tax_details_attributes = tax_details_attributes_for(params, amount_result)
      validate_amount_limits!(
        receipt_attributes: params[:receipt_attributes],
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: tax_details_attributes,
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      persist_result_full!(
        receipt_attributes: params[:receipt_attributes].merge(
          status: final_status,
          processing_error_code: nil,
          processing_error_message: nil,
          review_reasons: review_reasons,
          ocr_completed_at: Time.current,
          amount_calculation_profile: amount_calculation_profile_snapshot(amount_result, tax_rate_correction: params[:tax_rate_correction])
        ).merge(image_purge_candidate_attributes),
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: tax_details_attributes,
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      Rails.logger.info(
        "[ReceiptAnalysis] completed receipt_id=#{receipt.id} status=#{final_status} items=#{items_attributes.size}"
      )

      receipt
    end

    def save_ocr_only_result!(ocr_result)
      validate_source_structural_limits!(ocr_result: ocr_result)
      params = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: nil)
      params = Analysis.enforce_ownership_consistency(params: params)
      record_build_params_snapshot(params)
      validate_structural_limits!(params)

      # === AmountService integration point (OCR only) ===
      amount_result = ReceiptAmountService.call(
        receipt: params[:receipt_attributes],
        receipt_items: params[:receipt_items_attributes],
        receipt_tax_details: params[:receipt_tax_details_attributes],
        receipt_adjustments: params[:receipt_adjustments_attributes],
        receipt_payments: params[:receipt_payments_attributes],
        context: :analysis
      )
      amount_result = amount_result_with_receipt_amount_overrides(params, amount_result)

      params[:receipt_attributes].merge!(receipt_amount_attributes_for(params, amount_result))

      items_attributes = apply_amount_item_totals(
        apply_ocr_only_tax_rate_policy(params[:receipt_items_attributes], amount_result),
        amount_result.dig(:computed, :items)
      )
      tax_details_attributes = tax_details_attributes_for(params, amount_result)
      validate_amount_limits!(
        receipt_attributes: params[:receipt_attributes],
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: tax_details_attributes,
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      ocr_review_reasons = ocr_review_reasons_for(ocr_result)
      if low_quality_ocr?(ocr_result, receipt_attributes: params[:receipt_attributes])
        ocr_review_reasons << "ocr_low_confidence"
      end

      review_reasons = merge_review_reasons(
        params[:review_reasons],
        missing_core_review_reasons(params[:receipt_attributes]),
        detail_review_reasons_for(params),
        amount_review_reasons(amount_result),
        ocr_review_reasons
      )

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
        ).merge(image_purge_candidate_attributes),
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: tax_details_attributes,
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      Rails.logger.info(
        "[ReceiptAnalysis] ocr_only_completed receipt_id=#{receipt.id} status=#{final_status} items=#{items_attributes.size}"
      )

      receipt
    end

    def save_fallback_result!(ocr_result, error_code, processing_error_message: nil)
      validate_source_structural_limits!(ocr_result: ocr_result)
      params = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: nil)
      params = Analysis.enforce_ownership_consistency(params: params)
      record_build_params_snapshot(params)
      validate_structural_limits!(params)

      # === AmountService integration point (fallback) ===
      amount_result = ReceiptAmountService.call(
        receipt: params[:receipt_attributes],
        receipt_items: params[:receipt_items_attributes],
        receipt_tax_details: params[:receipt_tax_details_attributes],
        receipt_adjustments: params[:receipt_adjustments_attributes],
        receipt_payments: params[:receipt_payments_attributes],
        context: :analysis
      )
      amount_result = amount_result_with_receipt_amount_overrides(params, amount_result)

      params[:receipt_attributes].merge!(receipt_amount_attributes_for(params, amount_result))

      items_attributes = apply_amount_item_totals(
        apply_ocr_only_tax_rate_policy(params[:receipt_items_attributes], amount_result),
        amount_result.dig(:computed, :items)
      )
      tax_details_attributes = tax_details_attributes_for(params, amount_result)
      validate_amount_limits!(
        receipt_attributes: params[:receipt_attributes],
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: tax_details_attributes,
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      ocr_review_reasons = ocr_review_reasons_for(ocr_result)
      if low_quality_ocr?(ocr_result, receipt_attributes: params[:receipt_attributes])
        ocr_review_reasons << "ocr_low_confidence"
      end

      review_reasons = merge_review_reasons(
        params[:review_reasons],
        missing_core_review_reasons(params[:receipt_attributes]),
        amount_review_reasons(amount_result),
        ocr_review_reasons
      )
      mapped = Analysis.processing_error_mapping(error_code)

      receipt_attributes = params[:receipt_attributes].merge(
        status: "review_needed",
        processing_error_code: mapped[:error_code],
        processing_error_message: processing_error_message,
        review_reasons: review_reasons,
        ocr_completed_at: Time.current,
        amount_calculation_profile: amount_calculation_profile_snapshot(amount_result, tax_rate_correction: params[:tax_rate_correction])
      ).merge(image_purge_candidate_attributes)

      persist_result_full!(
        receipt_attributes: receipt_attributes,
        items_attributes: items_attributes,
        payments_attributes: params[:receipt_payments_attributes],
        tax_details_attributes: tax_details_attributes,
        adjustments_attributes: params[:receipt_adjustments_attributes]
      )

      Rails.logger.warn(
        "[ReceiptAnalysis] fallback_saved receipt_id=#{receipt.id} error_code=#{mapped[:error_code]} items=#{items_attributes.size}"
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
      }.merge(attributes).merge(image_purge_candidate_attributes)

      receipt.update!(receipt_attributes)

      Rails.logger.error(
        "[ReceiptAnalysis] failed receipt_id=#{receipt.id} error_code=#{error_code}"
      )

      receipt
    end

    def persist_result_full!(receipt_attributes:, items_attributes:, payments_attributes:, tax_details_attributes:, adjustments_attributes: [])
      validate_receipt_items_limit!(items_attributes)
      validate_collection_limit!(
        name: "receipt_adjustments",
        attributes: adjustments_attributes,
        limit: receipt_adjustments_limit
      )
      validate_collection_limit!(
        name: "receipt_payments",
        attributes: payments_attributes,
        limit: receipt_payments_limit
      )
      validate_collection_limit!(
        name: "receipt_tax_details",
        attributes: tax_details_attributes,
        limit: receipt_tax_details_limit
      )

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

    def validate_structural_limits!(params)
      validate_receipt_items_limit!(params[:receipt_items_attributes])
      validate_collection_limit!(
        name: "receipt_adjustments",
        attributes: params[:receipt_adjustments_attributes],
        limit: receipt_adjustments_limit
      )
      validate_collection_limit!(
        name: "receipt_payments",
        attributes: params[:receipt_payments_attributes],
        limit: receipt_payments_limit
      )
      validate_collection_limit!(
        name: "receipt_tax_details",
        attributes: params[:receipt_tax_details_attributes],
        limit: receipt_tax_details_limit
      )
    end

    def validate_amount_limits!(receipt_attributes:, items_attributes:, payments_attributes:, tax_details_attributes:, adjustments_attributes:)
      violation = ReceiptAmountLimits.violations_for(
        receipt: receipt_attributes,
        receipt_items: items_attributes,
        receipt_adjustments: adjustments_attributes,
        receipt_payments: payments_attributes,
        receipt_tax_details: tax_details_attributes
      ).first
      return if violation.blank?

      raise ReceiptAnalysisPipeline::AnalysisError.new(
        "analysis_value_invalid",
        "#{violation.fetch(:resource)}_amount_limit_exceeded field=#{violation.fetch(:field)} actual=#{violation.fetch(:actual_value)} limit=#{violation.fetch(:limit)}",
        metadata: amount_limit_exceeded_metadata(violation)
      )
    end

    def validate_receipt_items_limit!(items_attributes)
      limit = receipt.receipt_items_limit
      count = Array(items_attributes).size
      raise_limit_exceeded!(
        error: "analysis_items_invalid",
        resource: "receipt_items",
        limit: limit,
        actual_count: count,
        snapshot_count: count
      )
    end

    def validate_collection_limit!(name:, attributes:, limit:)
      count = Array(attributes).size
      raise_limit_exceeded!(
        error: "analysis_value_invalid",
        resource: name,
        limit: limit,
        actual_count: count,
        snapshot_count: count
      )
    end

    def validate_source_structural_limits!(ocr_result:, ai_result: nil)
      validate_source_collection_limit!(
        error: "analysis_items_invalid",
        resource: "receipt_items",
        count_metadata: ocr_candidate_count_metadata(ocr_result, :items),
        limit: receipt.receipt_items_limit
      )
      validate_source_collection_limit!(
        error: "analysis_value_invalid",
        resource: "receipt_payments",
        count_metadata: ocr_candidate_count_metadata(ocr_result, :payments),
        limit: receipt_payments_limit
      )
      validate_source_collection_limit!(
        error: "analysis_value_invalid",
        resource: "receipt_tax_details",
        count_metadata: ocr_candidate_count_metadata(ocr_result, :tax_details),
        limit: receipt_tax_details_limit
      )
      validate_source_collection_limit!(
        error: "analysis_value_invalid",
        resource: "receipt_adjustments",
        count_metadata: ocr_candidate_count_metadata(ocr_result, :adjustment_candidates),
        limit: receipt_adjustments_limit
      )
      return if ai_result.blank?

      validate_source_collection_limit!(
        error: "analysis_items_invalid",
        resource: "receipt_items",
        count_metadata: ai_attribute_count_metadata(ai_result, :receipt_items_attributes),
        limit: receipt.receipt_items_limit
      )
      validate_source_collection_limit!(
        error: "analysis_value_invalid",
        resource: "receipt_adjustments",
        count_metadata: ai_attribute_count_metadata(ai_result, :receipt_adjustments_attributes),
        limit: receipt_adjustments_limit
      )
    end

    def receipt_adjustments_limit
      ReceiptAdjustment.per_receipt_limit
    end

    def receipt_payments_limit
      ReceiptPayment.per_receipt_limit
    end

    def receipt_tax_details_limit
      ReceiptTaxDetail.per_receipt_limit
    end

    def validate_source_collection_limit!(error:, resource:, count_metadata:, limit:)
      actual_count = count_metadata[:actual_count]
      return if actual_count.nil?

      raise_limit_exceeded!(
        error: error,
        resource: resource,
        limit: limit,
        actual_count: actual_count,
        snapshot_count: count_metadata[:snapshot_count]
      )
    end

    def raise_limit_exceeded!(error:, resource:, limit:, actual_count:, snapshot_count: nil)
      return if actual_count <= limit

      raise ReceiptAnalysisPipeline::AnalysisError.new(
        error,
        "#{resource}_limit_exceeded count=#{actual_count} limit=#{limit}",
        metadata: limit_exceeded_metadata(
          error: error,
          resource: resource,
          limit: limit,
          actual_count: actual_count,
          snapshot_count: snapshot_count
        )
      )
    end

    def ocr_candidate_count_metadata(ocr_result, key)
      result = normalized_hash(ocr_result)
      counts = normalized_hash(result[:candidate_counts])
      metadata = normalize_count_metadata(counts[key])
      return metadata if metadata[:actual_count]

      values = Array(normalized_hash(result[:candidates])[key])
      { actual_count: values.size, snapshot_count: values.size }
    end

    def ai_attribute_count_metadata(ai_result, key)
      result = normalized_hash(ai_result)
      counts = normalized_hash(result[:attribute_counts])
      metadata = normalize_count_metadata(counts[key])
      return metadata if metadata[:actual_count]

      values = Array(result[key])
      { actual_count: values.size, snapshot_count: values.size }
    end

    def normalize_count_metadata(value)
      if value.respond_to?(:to_h)
        metadata = value.to_h.with_indifferent_access
        return {
          actual_count: normalize_count(metadata[:actual_count]),
          snapshot_count: normalize_count(metadata[:snapshot_count])
        }
      end

      count = normalize_count(value)
      { actual_count: count, snapshot_count: count }
    end

    def normalize_count(value)
      Integer(value, exception: false)
    end

    def limit_exceeded_metadata(error:, resource:, limit:, actual_count:, snapshot_count: nil)
      {
        error: error,
        resource: resource,
        limit: limit,
        actual_count: actual_count,
        snapshot_count: snapshot_count
      }.compact
    end

    def amount_limit_exceeded_metadata(violation)
      {
        error: "analysis_value_invalid",
        resource: violation.fetch(:resource),
        field: violation.fetch(:field),
        limit: violation.fetch(:limit),
        actual_value: violation.fetch(:actual_value),
        index: violation[:index]
      }.compact
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

        calculated_tax_rate = normalize_tax_rate(calculated_item[:tax_rate] || calculated_item["tax_rate"])

        item_attributes.merge(
          price: safe_calculated_amount(calculated_item[:price] || calculated_item["price"]) || item_attributes[:price],
          quantity: calculated_item[:quantity] || calculated_item["quantity"],
          tax_rate: calculated_tax_rate.nil? ? item_attributes[:tax_rate] : calculated_tax_rate,
          original_line_total: safe_calculated_amount(calculated_item[:original_line_total] || calculated_item["original_line_total"]) || item_attributes[:original_line_total],
          line_total: safe_calculated_amount(calculated_item[:line_total] || calculated_item["line_total"]) || item_attributes[:line_total],
          discount_amount: safe_calculated_amount(calculated_item[:discount_amount] || calculated_item["discount_amount"]) || item_attributes[:discount_amount],
          discount_rate: calculated_item[:discount_rate] || calculated_item["discount_rate"]
        )
      end
    end

    def determine_final_status(ocr_result:, receipt_attributes:, items_attributes:, ai_needs_review: nil, amount_needs_review: nil, build_review_reasons: [], ocr_review_reasons: [], detail_needs_review: nil, ocr_low_quality: nil)
      return "review_needed" if amount_needs_review
      return "review_needed" if ai_needs_review
      return "review_needed" if detail_needs_review
      return "review_needed" if ReviewReasons.blocking_reasons_for_user(build_review_reasons).any?
      return "review_needed" if ReviewReasons.blocking_reasons_for_user(ocr_review_reasons).any?
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
      ReviewReasons.review_reasons_for_user(
        reason_groups
        .flatten
        .compact
        .map(&:to_s)
        .reject(&:blank?)
        .uniq
      )
    end

    def missing_core_review_reasons(receipt_attributes)
      attributes = normalized_hash(receipt_attributes)

      [].tap do |reasons|
        reasons << "store_name_missing" if attributes[:store_name].blank?
        reasons << "purchased_at_missing" if attributes[:purchased_at].blank?
      end
    end

    def amount_review_reasons(amount_result)
      amount_reasons =
        if amount_result.key?(:blocking_inconsistencies)
          Array(amount_result[:blocking_inconsistencies])
        else
          Array(amount_result[:inconsistencies])
        end

      (amount_reasons + Array(amount_result[:review_reasons])).uniq
    end

    def detail_review_reasons_for(params)
      Array(params[:receipt_adjustments_attributes]).flat_map do |adjustment|
        normalize_review_reasons(normalized_hash(adjustment)[:review_reasons])
      end.uniq
    end

    def detail_needs_review?(params)
      Array(params[:receipt_adjustments_attributes]).any? do |adjustment|
        normalized = normalized_hash(adjustment)
        normalized[:needs_review] == true ||
          ReviewReasons.blocking_reasons_for_user(normalize_review_reasons(normalized[:review_reasons])).any?
      end
    end

    def amount_result_with_receipt_amount_overrides(params, amount_result)
      settlement_attributes = settlement_restored_receipt_amount_attributes(params, amount_result)
      return amount_result if settlement_attributes.blank?

      amount_result.deep_dup.tap do |result|
        resolved = normalized_hash(result[:resolved]).to_h
        result[:resolved] = resolved.merge(
          total: settlement_attributes[:total_amount],
          subtotal: settlement_attributes[:subtotal_amount],
          tax: settlement_attributes[:tax_amount],
          tax_rate: settlement_attributes[:tax_rate]
        )
      end
    end

    def receipt_amount_attributes_for(params, amount_result)
      settlement_attributes = settlement_restored_receipt_amount_attributes(params, amount_result)
      return settlement_attributes if settlement_attributes.present?

      resolved = normalized_hash(amount_result[:resolved])
      {
        total_amount: resolved[:total],
        subtotal_amount: resolved[:subtotal],
        tax_amount: resolved[:tax],
        tax_rate: resolved[:tax_rate]
      }
    end

    def tax_details_attributes_for(params, amount_result)
      settlement_tax_details = settlement_restored_tax_details_attributes(params)
      return settlement_tax_details if settlement_tax_details.present?

      amount_result[:tax_details]
    end

    def settlement_restored_receipt_amount_attributes(params, amount_result)
      hints = normalized_hash(params[:amount_hints])
      return nil unless hints[:settlement_total_from_deposit_change] == true

      receipt_attributes = normalized_hash(params[:receipt_attributes])
      restored_total = normalize_amount(hints[:settlement_total]) || normalize_amount(receipt_attributes[:total_amount])
      return nil unless restored_total&.positive?
      return nil unless receipt_payments_match_total?(params[:receipt_payments_attributes], restored_total)
      return nil unless amount_candidate_overrode_settlement_total?(amount_result, restored_total)

      resolved = normalized_hash(amount_result[:resolved])
      tax_amount = normalize_amount(receipt_attributes[:tax_amount]) || normalize_amount(resolved[:tax])

      {
        total_amount: restored_total,
        subtotal_amount: settlement_restored_subtotal(restored_total, tax_amount, receipt_attributes, resolved),
        tax_amount: tax_amount,
        tax_rate: resolved[:tax_rate] || receipt_attributes[:tax_rate]
      }
    end

    def settlement_restored_tax_details_attributes(params)
      hints = normalized_hash(params[:amount_hints])
      return nil unless hints[:settlement_total_from_deposit_change] == true

      receipt_attributes = normalized_hash(params[:receipt_attributes])
      restored_total = normalize_amount(hints[:settlement_total]) || normalize_amount(receipt_attributes[:total_amount])
      receipt_tax = normalize_amount(receipt_attributes[:tax_amount])
      tax_details = Array(params[:receipt_tax_details_attributes]).map { |tax_detail| normalized_hash(tax_detail) }
      return nil unless restored_total&.positive? && receipt_tax&.positive?
      return nil if tax_details.blank?
      return nil unless tax_details.all? { |tax_detail| complete_tax_detail_attributes?(tax_detail) }
      return nil unless tax_details.sum { |tax_detail| normalize_amount(tax_detail[:amount])&.to_i || 0 } == receipt_tax.to_i
      return nil unless tax_details.sum { |tax_detail| (normalize_amount(tax_detail[:net_amount])&.to_i || 0) + (normalize_amount(tax_detail[:amount])&.to_i || 0) } == restored_total.to_i

      tax_details.map(&:to_h)
    end

    def complete_tax_detail_attributes?(tax_detail)
      normalize_tax_rate(tax_detail[:rate]).present? &&
        normalize_amount(tax_detail[:net_amount])&.positive? &&
        normalize_amount(tax_detail[:amount])&.positive?
    end

    def receipt_payments_match_total?(payments, total)
      normalized_payments = Array(payments)
      return false if normalized_payments.blank?
      return false unless normalized_payments.any? { |payment| cash_payment_method?(normalized_hash(payment)[:method]) }

      normalized_payments.sum do |payment|
        normalize_amount(normalized_hash(payment)[:amount])&.to_i || 0
      end == total.to_i
    end

    def cash_payment_method?(method)
      method.to_s.match?(/\A\s*cash\s*\z/i) || method.to_s.match?(profile.finalize_cash_payment_method_pattern)
    end

    def amount_candidate_overrode_settlement_total?(amount_result, restored_total)
      resolved_total = normalize_amount(normalized_hash(amount_result[:resolved])[:total])
      return false if resolved_total.blank? || resolved_total.to_i == restored_total.to_i

      mismatch_reasons = [
        amount_result.dig(:amount_engine, :selected_candidate, :warnings),
        amount_result[:blocking_inconsistencies],
        amount_result[:warning_inconsistencies],
        amount_result[:inconsistencies],
        amount_result[:review_reasons]
      ].flatten.compact.map(&:to_s)

      mismatch_reasons.intersect?(%w[payment_amount_mismatch ocr_total_mismatch])
    end

    def settlement_restored_subtotal(restored_total, tax_amount, receipt_attributes, resolved)
      tax = normalize_amount(tax_amount)
      return restored_total.to_i - tax.to_i if tax&.positive? && restored_total.to_i >= tax.to_i

      receipt_subtotal = normalize_amount(receipt_attributes[:subtotal_amount])
      return receipt_subtotal if receipt_subtotal&.positive? && receipt_subtotal.to_i <= restored_total.to_i

      normalize_amount(resolved[:subtotal]) || restored_total
    end

    def item_total_drift_review_reasons(params, amount_result, ai_result:)
      return [] if Array(ai_result[:receipt_items_attributes]).blank?
      return [] if Array(params[:receipt_items_attributes]).blank?
      return [] unless item_total_drift_selected_basis?(amount_result)
      return [] if item_total_drift_suppressed?(params, amount_result)

      item_totals = item_total_drift_item_totals(params, amount_result)
      comparison_totals = item_total_drift_comparison_totals(params, amount_result)
      return [] if item_totals.blank? || comparison_totals.blank?
      matches_existing_total = item_totals.any? do |item_total|
        comparison_totals.any? { |comparison_total| item_total_drift_within_tolerance?(item_total, comparison_total) }
      end
      return [] if matches_existing_total

      [ ITEM_TOTAL_DRIFT_REVIEW_REASON ]
    end

    def item_total_drift_selected_basis?(amount_result)
      engine = normalized_hash(amount_result[:amount_engine])
      selected_candidate = normalized_hash(engine[:selected_candidate])
      basis = selected_candidate[:basis].presence || engine[:selected_basis].presence || engine[:selected_candidate_id].to_s.split("/").first

      ITEM_TOTAL_DRIFT_SELECTED_BASES.include?(basis.to_s)
    end

    def item_total_drift_suppressed?(params, amount_result)
      reasons = [
        params[:review_reasons],
        amount_result[:review_reasons],
        amount_result[:inconsistencies],
        amount_result[:blocking_inconsistencies],
        amount_result[:warning_inconsistencies]
      ].flatten.compact.map(&:to_s)

      reasons.intersect?(ITEM_TOTAL_DRIFT_SUPPRESSION_REASONS)
    end

    def item_total_drift_item_totals(params, amount_result)
      computed_items = Array(amount_result.dig(:computed, :items)).presence || Array(params[:receipt_items_attributes])
      item_total = computed_items.sum do |item|
        normalize_amount(normalized_hash(item)[:line_total])&.to_i || 0
      end
      adjusted_item_total = normalize_amount(amount_result.dig(:computed, :adjusted_item_total))&.to_i

      [ item_total, adjusted_item_total ].compact.select(&:positive?).uniq
    end

    def item_total_drift_comparison_totals(params, amount_result)
      resolved = normalized_hash(amount_result[:resolved])
      tax_details = Array(amount_result[:tax_details]).presence || Array(params[:receipt_tax_details_attributes])
      tax_detail_net_total = tax_details.sum do |tax_detail|
        normalize_amount(normalized_hash(tax_detail)[:net_amount])&.to_i || 0
      end
      tax_detail_gross_total = tax_details.sum do |tax_detail|
        normalized = normalized_hash(tax_detail)
        gross_amount = normalize_amount(normalized[:gross_amount])&.to_i
        next gross_amount if gross_amount&.positive?

        net_amount = normalize_amount(normalized[:net_amount])&.to_i || 0
        tax_amount = normalize_amount(normalized[:amount])&.to_i || 0
        net_amount + tax_amount
      end

      [
        normalize_amount(resolved[:subtotal])&.to_i,
        normalize_amount(resolved[:total])&.to_i,
        tax_detail_gross_total,
        tax_detail_net_total
      ].compact.select(&:positive?).uniq
    end

    def item_total_drift_within_tolerance?(item_total, comparison_total)
      drift = (item_total.to_i - comparison_total.to_i).abs

      drift <= item_total_drift_threshold(comparison_total)
    end

    def item_total_drift_threshold(comparison_total)
      relative_threshold = (BigDecimal(comparison_total.to_s) * ITEM_TOTAL_DRIFT_RELATIVE_THRESHOLD).ceil

      [ ITEM_TOTAL_DRIFT_ABSOLUTE_THRESHOLD, relative_threshold ].max
    end

    def clear_resolved_item_review_flags(items_attributes)
      Array(items_attributes).map do |item|
        normalized = normalized_hash(item)
        next item unless normalized[:needs_review] == true
        next item if normalize_review_reasons(normalized[:review_reasons]).any?
        next item if item_requires_review_from_final_values?(normalized)

        normalized.to_h.symbolize_keys.merge(needs_review: false)
      end
    end

    def item_requires_review_from_final_values?(item)
      confidence = normalize_confidence(item[:confidence])

      item[:raw_text].blank? ||
        item[:category].blank? ||
        item[:line_total].blank? ||
        (confidence.present? && confidence < REVIEW_NEEDED_CONFIDENCE_THRESHOLD)
    end

    def resolved_ai_review_reasons(ai_result, params, amount_result, ocr_result:)
      review_reasons = normalize_review_reasons(ai_result[:review_reasons])
      review_reasons = remove_resolved_store_name_missing_review_reason(review_reasons, params, amount_result, ocr_result)
      review_reasons = remove_resolved_store_name_uncertain_review_reason(review_reasons, params, ocr_result)
      review_reasons = remove_resolved_store_address_missing_review_reason(review_reasons, params, amount_result, ocr_result)
      review_reasons = remove_resolved_store_address_uncertain_review_reason(review_reasons, params, amount_result, ocr_result)
      review_reasons = remove_resolved_store_phone_number_missing_review_reason(review_reasons, params, amount_result, ocr_result)
      review_reasons = remove_resolved_purchased_at_conflicted_review_reason(review_reasons, params, ocr_result)
      review_reasons = remove_resolved_item_name_review_reasons(review_reasons, params, amount_result)
      review_reasons = remove_resolved_item_category_uncertain_review_reason(review_reasons, params)
      review_reasons = remove_resolved_item_tax_rate_uncertain_review_reason(review_reasons, params, amount_result)
      if Analysis.ownership_review_reason_resolved?(params: params, reason: ADJUSTMENT_UNCERTAIN_REVIEW_REASON)
        review_reasons -= [ ADJUSTMENT_UNCERTAIN_REVIEW_REASON ]
      end
      payment_method_reasons = %w[payment_method_missing payment_method_uncertain]
      return review_reasons unless review_reasons.intersect?(payment_method_reasons)
      return review_reasons unless payment_method_resolved_after_build?(params, amount_result)

      review_reasons - payment_method_reasons
    end

    def remove_resolved_store_phone_number_missing_review_reason(review_reasons, params, amount_result, ocr_result)
      return review_reasons unless review_reasons.include?("store_phone_number_missing")
      return review_reasons unless receipt_core_fields_resolved?(params, amount_result, ocr_result)

      review_reasons - [ "store_phone_number_missing" ]
    end

    def remove_resolved_store_address_missing_review_reason(review_reasons, params, amount_result, ocr_result)
      return review_reasons unless review_reasons.include?("store_address_missing")
      return review_reasons unless receipt_core_fields_resolved?(params, amount_result, ocr_result)

      review_reasons - [ "store_address_missing" ]
    end

    def remove_resolved_store_address_uncertain_review_reason(review_reasons, params, amount_result, ocr_result)
      return review_reasons unless review_reasons.include?("store_address_uncertain")
      return review_reasons unless receipt_core_fields_resolved?(params, amount_result, ocr_result)
      return review_reasons unless resolved_store_address_supported_by_ocr?(params, ocr_result)

      review_reasons - [ "store_address_uncertain" ]
    end

    def remove_resolved_purchased_at_conflicted_review_reason(review_reasons, params, ocr_result)
      return review_reasons unless review_reasons.include?(PURCHASED_AT_CONFLICTED_REVIEW_REASON)
      return review_reasons unless purchased_at_supported_by_ocr?(params, ocr_result)

      review_reasons - [ PURCHASED_AT_CONFLICTED_REVIEW_REASON ]
    end

    def remove_resolved_item_name_review_reasons(review_reasons, params, amount_result)
      review_reasons = remove_resolved_items_missing_review_reason(review_reasons, params, amount_result)
      target_reasons = [ ITEM_NAME_UNCERTAIN_REVIEW_REASON ]
      return review_reasons unless review_reasons.intersect?(target_reasons)
      return review_reasons unless item_names_resolved?(params, amount_result)

      review_reasons - target_reasons
    end

    def remove_resolved_items_missing_review_reason(review_reasons, params, amount_result)
      return review_reasons unless review_reasons.include?(ITEMS_MISSING_REVIEW_REASON)
      return review_reasons unless items_present_without_total_mismatch?(params, amount_result)

      review_reasons - [ ITEMS_MISSING_REVIEW_REASON ]
    end

    def remove_resolved_item_category_uncertain_review_reason(review_reasons, params)
      return review_reasons unless review_reasons.include?("item_category_uncertain")
      return review_reasons unless item_categories_resolved?(params)

      review_reasons - [ "item_category_uncertain" ]
    end

    def remove_resolved_item_tax_rate_uncertain_review_reason(review_reasons, params, amount_result)
      return review_reasons unless review_reasons.include?(ITEM_TAX_RATE_UNCERTAIN_REVIEW_REASON)
      return review_reasons unless item_tax_rates_resolved?(params, amount_result)

      review_reasons - [ ITEM_TAX_RATE_UNCERTAIN_REVIEW_REASON ]
    end

    def item_categories_resolved?(params)
      items = Array(params[:receipt_items_attributes])
      return false if items.blank?

      items.none? do |item|
        normalized = normalized_hash(item)
        item_category_review_unresolved?(normalized)
      end
    end

    def item_category_review_unresolved?(item)
      review_reasons = normalize_review_reasons(item[:review_reasons])
      return true if review_reasons.include?("item_category_uncertain")
      return false if item[:category].present?
      return false if item_name_review_reasons?(item)

      item_needs_review?(item)
    end

    def items_present_without_total_mismatch?(params, amount_result)
      return false if amount_review_reasons(amount_result).include?(ITEM_TOTAL_DRIFT_REVIEW_REASON)

      Array(params[:receipt_items_attributes]).any? do |item|
        normalized = normalized_hash(item)
        item_display_name(normalized).present? &&
          normalize_amount(normalized[:line_total]).present?
      end
    end

    def item_names_resolved?(params, amount_result)
      return false if amount_review_reasons(amount_result).include?(ITEM_TOTAL_DRIFT_REVIEW_REASON)

      items = Array(params[:receipt_items_attributes])
      return false if items.blank?

      items.none? do |item|
        normalized = normalized_hash(item)
        item_name_review_reasons?(normalized) ||
          item_needs_review?(normalized) ||
          item_display_name(normalized).blank?
      end
    end

    def item_name_review_reasons?(item)
      normalize_review_reasons(item[:review_reasons]).intersect?(
        [ ITEM_NAME_UNCERTAIN_REVIEW_REASON, ITEMS_MISSING_REVIEW_REASON ]
      )
    end

    def item_display_name(item)
      item[:confirmed_name].presence || item[:suggested_name].presence || item[:raw_text].presence
    end

    def item_tax_rates_resolved?(params, amount_result)
      return false if item_tax_rate_resolution_blocked?(amount_result)
      return true if non_taxable_item_tax_rates_resolved?(params, amount_result)

      tax_detail_rates = resolved_tax_detail_rates(params, amount_result)
      return false if tax_detail_rates.blank?

      item_rates = resolved_item_tax_rates(params)
      return false if item_rates.blank?

      (item_rates - tax_detail_rates).empty?
    end

    def non_taxable_item_tax_rates_resolved?(params, amount_result)
      return false unless resolved_tax_zero?(params, amount_result)
      return false unless tax_details_non_taxable_or_blank?(params, amount_result)

      items = Array(params[:receipt_items_attributes])
      return false if items.blank?

      items.all? do |item|
        normalized = normalized_hash(item)
        return false if normalize_review_reasons(normalized[:review_reasons]).include?(ITEM_TAX_RATE_UNCERTAIN_REVIEW_REASON)

        rate = normalize_tax_rate(normalized[:tax_rate])
        rate.nil? || rate.zero?
      end
    end

    def resolved_tax_zero?(params, amount_result)
      receipt_attributes = normalized_hash(params[:receipt_attributes])
      tax_amount = normalize_amount(normalized_hash(amount_result[:resolved])[:tax])
      tax_amount ||= normalize_amount(receipt_attributes[:tax_amount])

      tax_amount&.zero?
    end

    def tax_details_non_taxable_or_blank?(params, amount_result)
      tax_details = Array(amount_result[:tax_details]).presence || Array(params[:receipt_tax_details_attributes])
      return true if tax_details.blank?

      tax_details.all? do |tax_detail|
        normalized = normalized_hash(tax_detail)
        amount = normalize_amount(normalized[:amount])
        rate = normalize_tax_rate(normalized[:rate])

        (amount.nil? || amount.zero?) && (rate.nil? || rate.zero?)
      end
    end

    def item_tax_rate_resolution_blocked?(amount_result)
      reasons = [
        amount_review_reasons(amount_result),
        normalized_hash(amount_result[:amount_engine]).dig(:selected_candidate, :hard_reject_reasons)
      ].flatten.compact.map(&:to_s)

      reasons.intersect?(ITEM_TAX_RATE_RESOLUTION_BLOCKING_REASONS)
    end

    def resolved_tax_detail_rates(params, amount_result)
      tax_details = Array(amount_result[:tax_details]).presence || Array(params[:receipt_tax_details_attributes])
      tax_details.filter_map do |tax_detail|
        rate = normalize_tax_rate(normalized_hash(tax_detail)[:rate])
        rate&.positive? ? rate : nil
      end.uniq
    end

    def resolved_item_tax_rates(params)
      Array(params[:receipt_items_attributes]).filter_map do |item|
        normalized = normalized_hash(item)
        return [] if normalize_review_reasons(normalized[:review_reasons]).include?(ITEM_TAX_RATE_UNCERTAIN_REVIEW_REASON)

        rate = normalize_tax_rate(normalized[:tax_rate])
        rate&.positive? ? rate : nil
      end.uniq
    end

    def receipt_core_fields_resolved?(params, amount_result, ocr_result)
      receipt_attributes = normalized_hash(params[:receipt_attributes])
      return false if receipt_attributes[:store_name].blank?
      return false unless store_address_resolved_or_optional?(receipt_attributes, ocr_result)
      return false if receipt_attributes[:purchased_at].blank?
      return false if normalize_amount(receipt_attributes[:total_amount]).blank?

      payment_method_resolved_after_build?(params, amount_result)
    end

    def store_address_resolved_or_optional?(receipt_attributes, ocr_result)
      return true if receipt_attributes[:store_address].present?

      ocr_candidates(ocr_result)[:store_address].blank?
    end

    def remove_resolved_store_name_uncertain_review_reason(review_reasons, params, ocr_result)
      return review_reasons unless review_reasons.include?("store_name_uncertain")
      return review_reasons unless resolved_store_name_supported_by_ocr?(params, ocr_result)

      review_reasons - [ "store_name_uncertain" ]
    end

    def remove_resolved_store_name_missing_review_reason(review_reasons, params, amount_result, ocr_result)
      return review_reasons unless review_reasons.include?("store_name_missing")
      return review_reasons unless receipt_core_fields_resolved?(params, amount_result, ocr_result)
      return review_reasons unless resolved_store_name_supported_by_ocr?(params, ocr_result)

      review_reasons - [ "store_name_missing" ]
    end

    def resolved_store_address_supported_by_ocr?(params, ocr_result)
      store_address = normalized_hash(params[:receipt_attributes])[:store_address].to_s
      compact_address = compact_address_for_review(store_address)
      return false if compact_address.blank?

      ocr_address_candidates(ocr_result).any? do |candidate|
        compact_candidate = compact_address_for_review(candidate)
        next false if compact_candidate.blank?

        compact_candidate == compact_address ||
          compact_candidate.include?(compact_address) ||
          compact_address.include?(compact_candidate)
      end
    end

    def ocr_address_candidates(ocr_result)
      [
        ocr_candidates(ocr_result)[:store_address],
        *Array(ocr_result[:lines]).first(8)
      ].compact
    end

    def compact_address_for_review(value)
      value.to_s
        .unicode_normalize(:nfkc)
        .downcase
        .gsub(/[[:space:]\-−ー‐‑‒–—―・,，、。:：]/, "")
    end

    def purchased_at_supported_by_ocr?(params, ocr_result)
      purchased_at = parse_time_value(normalized_hash(params[:receipt_attributes])[:purchased_at])
      return false unless purchased_at.respond_to?(:strftime)

      text = ocr_datetime_support_text(ocr_result)
      return false if text.blank?

      date_variants = [
        purchased_at.strftime("%Y-%m-%d"),
        purchased_at.strftime("%Y/%m/%d"),
        purchased_at.strftime("%Y%m%d"),
        "#{purchased_at.year}年#{purchased_at.month}月#{purchased_at.day}日",
        purchased_at.strftime("%Y年%m月%d日")
      ].uniq
      time_variants = [
        purchased_at.strftime("%H:%M"),
        "#{purchased_at.hour}:#{purchased_at.min.to_s.rjust(2, '0')}",
        "#{purchased_at.hour}時#{purchased_at.min.to_s.rjust(2, '0')}分"
      ].uniq

      date_variants.any? { |date| text.include?(date) } &&
        (purchased_at.hour.zero? && purchased_at.min.zero? || time_variants.any? { |time| text.include?(time) })
    end

    def ocr_datetime_support_text(ocr_result)
      candidates = normalized_hash(ocr_result[:candidates])
      [
        ocr_result[:raw_text],
        ocr_result[:lines],
        candidates[:purchased_at_text],
        candidates[:purchased_at_candidates]
      ].flatten.compact.join("\n")
    end

    def resolved_store_name_supported_by_ocr?(params, ocr_result)
      store_name = Analysis.normalize_store_name_candidate(
        params.dig(:receipt_attributes, :store_name)
      )
      return false unless resolved_customer_facing_store_name?(store_name)

      compact_store_name = compact_store_name_for_review(store_name)
      header_lines = Array(ocr_result[:lines]).first(8).filter_map do |line|
        Analysis.normalize_store_name_candidate(line)
      end
      return true if header_lines.any? { |line| compact_store_name_for_review(line) == compact_store_name }

      return true if latin_logo_local_store_name_supported_by_ocr?(store_name, header_lines)

      Analysis.store_name_customer_facing_heading_candidates(header_lines).any? do |candidate|
        compact_store_name_for_review(candidate) == compact_store_name
      end
    end

    def latin_logo_local_store_name_supported_by_ocr?(store_name, header_lines)
      parts = store_name.to_s.split
      return false if parts.size < 3

      brand = parts.first
      branch = parts.last
      descriptor = parts[1...-1].join
      return false if brand.blank? || descriptor.blank? || branch.blank?

      latin_brand_supported_by_header?(brand, header_lines) &&
        descriptor_supported_by_header?(descriptor, header_lines) &&
        branch_supported_by_header?(branch, header_lines)
    end

    def latin_brand_supported_by_header?(brand, header_lines)
      compact_brand = compact_store_name_for_review(brand)
      return false unless compact_brand.match?(/\A[a-z0-9&.'-]{2,30}\z/)

      Array(header_lines).first(3).any? do |line|
        compact_line = compact_store_name_for_review(line)
        compact_line == compact_brand ||
          compact_line.start_with?(compact_brand) ||
          compact_brand.start_with?(compact_line)
      end
    end

    def descriptor_supported_by_header?(descriptor, header_lines)
      compact_descriptor = compact_store_name_for_review(descriptor)
      return false if compact_descriptor.blank?

      Array(header_lines).any? do |line|
        compact_store_name_for_review(line).include?(compact_descriptor)
      end
    end

    def branch_supported_by_header?(branch, header_lines)
      compact_branch = compact_store_name_for_review(branch)
      return false if compact_branch.blank?

      Array(header_lines).any? do |line|
        compact_line = compact_store_name_for_review(line)
        compact_line == compact_branch
      end
    end

    def resolved_customer_facing_store_name?(store_name)
      normalized = store_name.to_s
      return false if normalized.blank?
      return false if normalized.length < 2 || normalized.length > 60
      return false if Analysis.store_name_legal_entity_name?(normalized)
      return false if Analysis.store_name_operator_context_line?(normalized)
      return false if Analysis.store_name_descriptive_heading_line?(normalized)
      return false if Analysis.store_name_message_line?(normalized)
      return false if Analysis.store_name_isolated_logo_fragment?(normalized)
      return false if normalized.split.any? { |part| Analysis.store_name_isolated_logo_fragment?(part) }
      return false if normalized.match?(/[¥￥$€£]|\b(?:receipt|invoice|total|subtotal|tax|payment)\b/i)
      return false if normalized.match?(/\d{4}[\/\-年]\s*\d{1,2}[\/\-月]\s*\d{1,2}日?|\d{1,2}[:：]\d{2}/)
      return false if normalized.match?(profile.store_context_address_pattern)

      normalized.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)
    end

    def compact_store_name_for_review(value)
      Analysis.normalize_compact_store_name_candidate(value).to_s.downcase
    end

    def payment_method_resolved_after_build?(params, amount_result)
      receipt_attributes = (params[:receipt_attributes] || {}).with_indifferent_access
      return false if receipt_attributes[:payment_method].blank?

      payments = Array(params[:receipt_payments_attributes])
      return false if payments.blank?

      final_payment_total = final_payment_total_from_amount_result(amount_result)
      return false unless final_payment_total&.positive?

      payments.sum { |payment| payment.with_indifferent_access[:amount].to_i } == final_payment_total
    end

    def final_payment_total_from_amount_result(amount_result)
      result = amount_result.respond_to?(:with_indifferent_access) ? amount_result.with_indifferent_access : {}
      selected_candidate = result.dig(:amount_engine, :selected_candidate) || {}
      selected_candidate[:final_payment_total] || result.dig(:resolved, :total)
    end

    def ocr_review_reasons_for(ocr_result)
      candidates = ocr_candidates(ocr_result)
      ReviewReasons.review_reasons_for_user(candidates[:review_reasons])
    end

    def amount_calculation_profile_snapshot(amount_result, tax_rate_correction: nil)
      snapshot = ReceiptAmountService.calculation_profile_snapshot(amount_result)
      snapshot = remove_resolved_tax_detail_rate_mismatch_warning(snapshot, amount_result)
      return snapshot if tax_rate_correction.blank?

      snapshot[:profile] ||= {}
      snapshot[:profile][:tax_rate_correction] = tax_rate_correction
      snapshot
    end

    def remove_resolved_tax_detail_rate_mismatch_warning(snapshot, amount_result)
      return snapshot unless tax_detail_rate_mismatch_warning_present?(snapshot)
      return snapshot unless resolved_tax_details_match_amounts?(amount_result)

      snapshot.deep_dup.tap do |copy|
        copy[:warnings] = Array(copy[:warnings]) - [ "tax_detail_rate_mismatch" ]
        copy[:mismatch_codes] = Array(copy[:mismatch_codes]) - [ "TAX_DETAIL_RATE_MISMATCH" ]
        copy[:warning_mismatch_codes] = Array(copy[:warning_mismatch_codes]) - [ "TAX_DETAIL_RATE_MISMATCH" ]
      end
    end

    def tax_detail_rate_mismatch_warning_present?(snapshot)
      Array(snapshot[:warnings]).include?("tax_detail_rate_mismatch") ||
        Array(snapshot[:mismatch_codes]).include?("TAX_DETAIL_RATE_MISMATCH") ||
        Array(snapshot[:warning_mismatch_codes]).include?("TAX_DETAIL_RATE_MISMATCH")
    end

    def resolved_tax_details_match_amounts?(amount_result)
      return false if amount_review_reasons(amount_result).map(&:to_s).intersect?(%w[tax_amount_mismatch tax_detail_mismatch])

      tax_details = Array(amount_result[:tax_details])
      return false if tax_details.blank?

      resolved = normalized_hash(amount_result[:resolved])
      subtotal = normalize_amount(resolved[:subtotal])
      tax = normalize_amount(resolved[:tax])
      total = normalize_amount(resolved[:total])
      return false if subtotal.nil? || tax.nil? || total.nil?

      net_sum = tax_details.sum { |tax_detail| normalize_amount(normalized_hash(tax_detail)[:net_amount]).to_i }
      tax_sum = tax_details.sum { |tax_detail| normalize_amount(normalized_hash(tax_detail)[:amount]).to_i }

      net_sum == subtotal.to_i &&
        tax_sum == tax.to_i &&
        net_sum + tax_sum == total.to_i
    end

    def record_build_params_snapshot(params)
      return if run.blank?

      ReceiptAnalysisRuns.record_build_params_snapshot(run, params)
    end

    def image_purge_candidate_attributes
      return {} unless receipt.image_retention_disabled?
      return {} unless receipt.image.attached?

      {
        image_purge_eligible_at: Time.current,
        image_purged_at: nil,
        image_purged_reason: nil
      }
    end

    def normalize_items_attributes(items)
      Array(items).filter_map.with_index do |item, index|
        symbolized =
          if item.respond_to?(:with_indifferent_access)
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
        quantity_unit_code = ReceiptQuantityUnit.normalize(symbolized[:quantity_unit_code])

        {
          raw_text: symbolized[:raw_text].to_s,
          suggested_name: symbolized[:suggested_name].presence,
          confirmed_name: symbolized[:confirmed_name].presence,
          category: symbolized[:category].presence,
          price: price,
          quantity: normalize_quantity(symbolized[:quantity]),
          quantity_unit_code: quantity_unit_code,
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
        symbolized =
          if adjustment.respond_to?(:with_indifferent_access)
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
        normalized_item =
          if item_attributes.respond_to?(:with_indifferent_access)
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

    def profile
      ReceiptAnalysisProfiles.default
    end
  end
end
