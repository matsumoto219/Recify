module ReceiptAnalysisRuns
  class SnapshotBuilder
    OCR_SUMMARY_SCHEMA_VERSION = "receipt_analysis_run_ocr_summary_v1"
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"
    AI_INPUT_SCHEMA_VERSION = "receipt_analysis_run_ai_input_v1"
    AI_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ai_result_v1"
    AI_NORMALIZED_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ai_normalized_result_v1"
    FINALIZE_DECISION_SCHEMA_VERSION = ReceiptAnalysisPipeline::FINALIZE_DECISION_SCHEMA_VERSION
    BUILD_PARAMS_SCHEMA_VERSION = "receipt_analysis_run_build_params_v1"
    FINAL_RESULT_SCHEMA_VERSION = "receipt_analysis_run_final_result_v1"
    PROMPT_SCHEMA_VERSION = "recify_receipt_analysis_v1"

    FINALIZE_STRATEGIES = ReceiptAnalysisPipeline::FINALIZE_STRATEGIES
    FINALIZE_DECISION_RECEIPT_ATTRIBUTE_KEYS = %w[country_region].freeze
    FINALIZE_DECISION_METADATA_KEYS = %w[reason].freeze

    MAX_OCR_LINES = 150
    DEFAULT_MAX_OCR_ITEMS = 1000
    MAX_OCR_ITEMS = DEFAULT_MAX_OCR_ITEMS
    DEFAULT_MAX_OCR_PAYMENTS = 20
    MAX_OCR_PAYMENTS = DEFAULT_MAX_OCR_PAYMENTS
    DEFAULT_MAX_OCR_TAX_DETAILS = 20
    MAX_OCR_TAX_DETAILS = DEFAULT_MAX_OCR_TAX_DETAILS
    DEFAULT_MAX_AI_NORMALIZED_ITEMS = 1000
    MAX_AI_NORMALIZED_ITEMS = DEFAULT_MAX_AI_NORMALIZED_ITEMS
    MAX_FULL_CONTEXT_LINES = 150
    MAX_ADJUSTMENT_CONTEXT_LINES = 40
    FILTERED_CONTENT_MAX_BYTES = 8 * 1024
    STRING_MAX_BYTES = 500
    MAX_ITEMS = 50
    MAX_STORE_CANDIDATES = 10
    MAX_PURCHASED_AT_CANDIDATES = 5
    MAX_PAYMENT_CANDIDATES = 10
    MAX_TAX_DETAILS = 10
    MAX_REVIEW_REASONS = 20

    EXACT_FORBIDDEN_KEYS = %w[
      api_key
      authorization
      azure_raw_response
      blob_key
      cookie
      cookies
      full_prompt
      headers
      image
      image_payload
      messages
      openai_raw_response
      prompt
      prompt_text
      provider_raw_response
      raw_ai_response
      raw_response
      response_body
      secret
      signed_id
      system_prompt
      token
      user_prompt
    ].freeze
    FORBIDDEN_KEY_FRAGMENTS = %w[
      authorization
      password
      secret
      signed_id
    ].freeze

    class << self
      def ocr_summary(ocr_result)
        new.ocr_summary(ocr_result)
      end

      def ocr_result_snapshot(ocr_result)
        new.ocr_result_snapshot(ocr_result)
      end

      def ai_input_snapshot(ai_input)
        new.ai_input_snapshot(ai_input)
      end

      def ai_result_summary(ai_result)
        new.ai_result_summary(ai_result)
      end

      def ai_normalized_result_snapshot(ai_result)
        new.ai_normalized_result_snapshot(ai_result)
      end

      def finalize_decision_snapshot(decision, at: Time.current)
        new.finalize_decision_snapshot(decision, at: at)
      end

      def build_params_snapshot(build_params)
        new.build_params_snapshot(build_params)
      end

      def final_result_summary(receipt: nil, receipt_attributes: nil, items_attributes: nil, payments_attributes: nil, tax_details_attributes: nil, adjustments_attributes: nil, amount_result: nil)
        new.final_result_summary(
          receipt: receipt,
          receipt_attributes: receipt_attributes,
          items_attributes: items_attributes,
          payments_attributes: payments_attributes,
          tax_details_attributes: tax_details_attributes,
          adjustments_attributes: adjustments_attributes,
          amount_result: amount_result
        )
      end

      def sanitized_stored_snapshot(snapshot)
        new.sanitized_stored_snapshot(snapshot)
      end

      def snapshot_ocr_items_max
        snapshot_limit_for("limits.snapshot_ocr_items_max", DEFAULT_MAX_OCR_ITEMS)
      end

      def snapshot_ai_normalized_items_max
        snapshot_limit_for("limits.snapshot_ai_normalized_items_max", DEFAULT_MAX_AI_NORMALIZED_ITEMS)
      end

      def snapshot_ocr_lines_max
        snapshot_limit_for("limits.snapshot_ocr_lines_max", MAX_OCR_LINES)
      end

      def snapshot_ai_input_full_context_lines_max
        snapshot_limit_for("limits.snapshot_ai_input_full_context_lines_max", MAX_FULL_CONTEXT_LINES)
      end

      def snapshot_ai_input_adjustment_context_lines_max
        snapshot_limit_for("limits.snapshot_ai_input_adjustment_context_lines_max", MAX_ADJUSTMENT_CONTEXT_LINES)
      end

      def snapshot_ai_input_filtered_content_max_bytes
        snapshot_limit_for("limits.snapshot_ai_input_filtered_content_max_bytes", FILTERED_CONTENT_MAX_BYTES)
      end

      def snapshot_string_max_bytes
        snapshot_limit_for("limits.snapshot_string_max_bytes", STRING_MAX_BYTES)
      end

      def snapshot_ai_input_items_max
        snapshot_limit_for("limits.snapshot_ai_input_items_max", MAX_ITEMS)
      end

      def snapshot_store_candidates_max
        snapshot_limit_for("limits.snapshot_store_candidates_max", MAX_STORE_CANDIDATES)
      end

      def snapshot_purchase_candidates_max
        snapshot_limit_for("limits.snapshot_purchase_candidates_max", MAX_PURCHASED_AT_CANDIDATES)
      end

      def snapshot_payment_candidates_max
        snapshot_limit_for("limits.snapshot_payment_candidates_max", MAX_PAYMENT_CANDIDATES)
      end

      def snapshot_tax_details_max
        snapshot_limit_for("limits.snapshot_tax_details_max", MAX_TAX_DETAILS)
      end

      def snapshot_review_reasons_max
        snapshot_limit_for("limits.snapshot_review_reasons_max", MAX_REVIEW_REASONS)
      end

      def snapshot_limit_for(key, fallback)
        SystemSettings.limit_for(key)
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        fallback
      end
    end

    def sanitized_stored_snapshot(snapshot)
      sanitized = sanitize_value(snapshot)
      sanitized.is_a?(Hash) ? sanitized : {}
    end

    def finalize_decision_snapshot(decision, at: Time.current)
      strategy = safe_string(decision&.finalize_strategy || decision&.strategy)
      strategy = nil unless FINALIZE_STRATEGIES.include?(strategy)

      sanitize_hash(
        {
          schema_version: FINALIZE_DECISION_SCHEMA_VERSION,
          strategy: strategy,
          error_code: safe_string(decision&.error_code),
          error_message: safe_finalize_error_message(decision&.error_message, error_code: decision&.error_code),
          receipt_attributes: finalize_decision_receipt_attributes(decision&.receipt_attributes),
          metadata: finalize_decision_metadata(decision&.metadata),
          recorded_at: safe_value(at)
        }.compact
      )
    end

    def build_params_snapshot(build_params)
      params = normalized_hash(build_params)
      receipt_attrs = normalized_hash(params[:receipt_attributes])

      sanitize_hash(
        {
          schema_version: BUILD_PARAMS_SCHEMA_VERSION,
          receipt_attributes: build_params_receipt_attributes(receipt_attrs),
          receipt_items_count: Array(params[:receipt_items_attributes]).size,
          receipt_payments_count: Array(params[:receipt_payments_attributes]).size,
          receipt_tax_details_count: Array(params[:receipt_tax_details_attributes]).size,
          receipt_adjustments_count: Array(params[:receipt_adjustments_attributes]).size,
          corrections: build_params_corrections_snapshot(params[:corrections], params[:tax_rate_correction]),
          review_reasons: limited_strings(params[:review_reasons], snapshot_review_reasons_limit)
        }.compact
      )
    end

    def ocr_summary(ocr_result)
      result = normalized_hash(ocr_result)
      candidates = normalized_hash(result[:candidates])
      meta = normalized_hash(result[:meta])

      sanitize_hash(
        {
          schema_version: OCR_SUMMARY_SCHEMA_VERSION,
          success: result[:success] == true,
          error_code: safe_string(result[:error_code]),
          provider: safe_string(meta[:provider]),
          model: safe_string(meta[:model_id] || meta[:model]),
          doc_type: safe_string(meta[:doc_type]),
          country_region: safe_string(candidates[:country_region]),
          line_count: Array(result[:lines]).size,
          raw_text_length: result[:raw_text].to_s.length,
          item_count: Array(candidates[:items]).size,
          payment_count: Array(candidates[:payments]).size,
          tax_detail_count: Array(candidates[:tax_details]).size,
          presence: {
            store_name: candidates[:store_name].present?,
            total_amount: candidates[:total_amount].present?,
            payment_method_text: candidates[:payment_method_text].present?,
            items: Array(candidates[:items]).present?
          },
          confidence_summary: sanitized_confidence_summary(candidates[:confidence_summary]),
          polling_metrics: sanitized_polling_metrics(meta[:polling_metrics]).presence,
          provider_error_detail: provider_error_detail_snapshot(meta[:provider_error_detail]).presence
        }.compact
      )
    end

    def ocr_result_snapshot(ocr_result)
      result = normalized_hash(ocr_result)
      candidates = normalized_hash(result[:candidates])
      ocr_lines_limit = snapshot_ocr_lines_limit
      lines = limited_strings(result[:lines], ocr_lines_limit)
      candidates_snapshot = ocr_candidates_snapshot(candidates)

      sanitize_hash(
        {
          schema_version: OCR_RESULT_SCHEMA_VERSION,
          success: result[:success] == true,
          lines: lines,
          candidates: candidates_snapshot,
          candidate_counts: ocr_candidate_counts(candidates, candidates_snapshot),
          error_code: safe_string(result[:error_code]),
          meta: ocr_meta_snapshot(result[:meta]),
          truncated: {
            lines: Array(result[:lines]).size > ocr_lines_limit,
            items: Array(candidates[:items]).size > ocr_items_snapshot_limit,
            payments: Array(candidates[:payments]).size > receipt_payments_snapshot_limit,
            tax_details: Array(candidates[:tax_details]).size > receipt_tax_details_snapshot_limit,
            adjustment_candidates: Array(candidates[:adjustment_candidates]).size > receipt_adjustments_snapshot_limit
          }
        }.compact
      )
    end

    def ai_input_snapshot(ai_input)
      input = normalized_hash(ai_input)

      filtered_content_max_bytes = snapshot_ai_input_filtered_content_limit
      ai_input_items_limit = snapshot_ai_input_items_limit
      full_context_lines_limit = snapshot_ai_input_full_context_lines_limit
      adjustment_context_lines_limit = snapshot_ai_input_adjustment_context_lines_limit
      filtered_content = truncate_string(input[:filtered_content], max_bytes: filtered_content_max_bytes)
      items = limited_items(input[:items])

      sanitize_hash(
        {
          schema_version: AI_INPUT_SCHEMA_VERSION,
          prompt_schema_version: PROMPT_SCHEMA_VERSION,
          filtered_content: filtered_content,
          full_context_lines: limited_context_lines(input[:full_context_lines], full_context_lines_limit),
          store: store_snapshot(input[:store]),
          purchase: purchase_snapshot(input[:purchase]),
          payment: payment_snapshot(input[:payment]),
          tax: tax_snapshot(input[:tax]),
          items: items,
          adjustment_context_lines: limited_adjustment_context_lines(input[:adjustment_context_lines]),
          meta: ai_input_meta_snapshot(input[:meta]),
          truncated: {
            filtered_content: truncated?(input[:filtered_content], max_bytes: filtered_content_max_bytes),
            items: Array(input[:items]).size > ai_input_items_limit,
            full_context_lines: Array(input[:full_context_lines]).size > full_context_lines_limit,
            adjustment_context_lines: Array(input[:adjustment_context_lines]).size > adjustment_context_lines_limit
          }
        }.compact
      )
    end

    def ai_normalized_result_snapshot(ai_result)
      result = normalized_hash(ai_result)
      receipt_items_snapshot = limited_ai_normalized_items(result[:receipt_items_attributes])
      receipt_adjustments_snapshot = limited_ai_normalized_adjustments(result[:receipt_adjustments_attributes])

      sanitize_hash(
        {
          schema_version: AI_NORMALIZED_RESULT_SCHEMA_VERSION,
          success: result[:success] == true,
          error_code: safe_string(result[:error_code]),
          needs_review: result[:needs_review] == true,
          review_reasons: limited_strings(result[:review_reasons], snapshot_review_reasons_limit),
          receipt_attributes: normalized_receipt_attributes_snapshot(result[:receipt_attributes]),
          receipt_items_attributes: receipt_items_snapshot,
          receipt_adjustments_attributes: receipt_adjustments_snapshot,
          attribute_counts: ai_normalized_attribute_counts(
            result,
            receipt_items_snapshot: receipt_items_snapshot,
            receipt_adjustments_snapshot: receipt_adjustments_snapshot
          ),
          meta: ai_normalized_meta_snapshot(result[:meta]),
          truncated: {
            receipt_items_attributes: Array(result[:receipt_items_attributes]).size > ai_normalized_items_snapshot_limit,
            receipt_adjustments_attributes: Array(result[:receipt_adjustments_attributes]).size > receipt_adjustments_snapshot_limit,
            review_reasons: Array(result[:review_reasons]).size > snapshot_review_reasons_limit
          }
        }.compact
      )
    end

    def ai_result_summary(ai_result)
      result = normalized_hash(ai_result)
      meta = normalized_hash(result[:meta])

      sanitize_hash(
        {
          schema_version: AI_RESULT_SCHEMA_VERSION,
          success: result[:success] == true,
          needs_review: result[:needs_review] == true,
          error_code: safe_string(result[:error_code]),
          review_reasons: limited_strings(result[:review_reasons], snapshot_review_reasons_limit),
          provider: safe_string(meta[:provider] || meta[:primary_provider]),
          model: safe_string(meta[:model]),
          fallback_provider: safe_string(meta[:fallback_provider]),
          fallback_used: meta[:fallback_used] == true,
          final_provider: safe_string(meta[:final_provider]),
          primary_error_detail: provider_error_detail_snapshot(meta[:primary_error_detail]).presence,
          fallback_error_detail: provider_error_detail_snapshot(meta[:fallback_error_detail]).presence,
          final_error_detail: provider_error_detail_snapshot(meta[:final_error_detail]).presence,
          metrics: sanitized_ai_metrics(meta[:metrics]).presence,
          document_type: safe_string(meta[:document_type]),
          rejection_reason: safe_string(meta[:rejection_reason]),
          item_count: Array(result[:receipt_items_attributes]).size,
          adjustment_count: Array(result[:receipt_adjustments_attributes]).size,
          receipt_attributes_keys: normalized_hash(result[:receipt_attributes]).keys.map(&:to_s).sort
        }.compact
      )
    end

    def final_result_summary(receipt: nil, receipt_attributes: nil, items_attributes: nil, payments_attributes: nil, tax_details_attributes: nil, adjustments_attributes: nil, amount_result: nil)
      receipt_attrs = normalized_hash(receipt_attributes)
      amount = normalized_hash(amount_result)

      sanitize_hash(
        {
          schema_version: FINAL_RESULT_SCHEMA_VERSION,
          receipt_status: safe_string(receipt_attrs[:status] || receipt&.status),
          processing_error_code: safe_string(receipt_attrs[:processing_error_code] || receipt&.processing_error_code),
          review_reasons: limited_strings(receipt_attrs[:review_reasons] || receipt&.review_reasons, snapshot_review_reasons_limit),
          item_count: count_records(items_attributes, receipt&.receipt_items),
          payment_count: count_records(payments_attributes, receipt&.receipt_payments),
          tax_detail_count: count_records(tax_details_attributes, receipt&.receipt_tax_details),
          adjustment_count: count_records(adjustments_attributes, receipt&.receipt_adjustments),
          amount: amount_snapshot(receipt, receipt_attrs),
          amount_mismatch_codes: limited_strings(amount[:mismatch_codes], snapshot_review_reasons_limit),
          amount_blocking_mismatch_codes: limited_strings(amount[:blocking_mismatch_codes], snapshot_review_reasons_limit),
          amount_warning_mismatch_codes: limited_strings(amount[:warning_mismatch_codes], snapshot_review_reasons_limit)
        }.compact
      )
    end

    private

    def finalize_decision_receipt_attributes(value)
      attributes = normalized_hash(value)

      FINALIZE_DECISION_RECEIPT_ATTRIBUTE_KEYS.each_with_object({}) do |key, memo|
        memo[key] = safe_string(attributes[key]) if attributes[key].present?
      end
    end

    def finalize_decision_metadata(value)
      metadata = normalized_hash(value)

      FINALIZE_DECISION_METADATA_KEYS.each_with_object({}) do |key, memo|
        memo[key] = safe_string(metadata[key]) if metadata[key].present?
      end
    end

    def safe_finalize_error_message(value, error_code:)
      return nil if value.blank?
      return nil if error_code.to_s == "unexpected_error"

      message = safe_string(value)
      return nil if unsafe_finalize_error_message?(message)

      message
    end

    def unsafe_finalize_error_message?(message)
      message.to_s.match?(
        /#<|Net::|api[_ -]?key|authorization|blob[_ -]?key|cookie|messages|password|prompt|raw[_ -]?response|response[_ -]?body|secret|signed[_ -]?id|sk-[A-Za-z0-9]/i
      )
    end

    def build_params_receipt_attributes(attributes)
      {
        store_name: safe_string(attributes[:store_name]),
        store_address: safe_string(attributes[:store_address]),
        store_address_components: sanitize_hash(attributes[:store_address_components]).presence,
        store_phone_number: safe_string(attributes[:store_phone_number]),
        purchased_at: safe_value(attributes[:purchased_at]),
        total_amount: safe_value(attributes[:total_amount]),
        subtotal_amount: safe_value(attributes[:subtotal_amount]),
        tax_amount: safe_value(attributes[:tax_amount]),
        tax_rate: safe_value(attributes[:tax_rate]),
        currency_code: safe_string(attributes[:currency_code]),
        payment_method: safe_string(attributes[:payment_method]),
        country_region: safe_string(attributes[:country_region]),
        receipt_type: safe_string(attributes[:receipt_type]),
        processing_error_code: safe_string(attributes[:processing_error_code])
      }.compact
    end

    def build_params_corrections_snapshot(corrections, tax_rate_correction)
      normalized = normalized_hash(corrections).to_h
      normalized["tax_rate_correction"] ||= tax_rate_correction if tax_rate_correction.present?

      sanitize_hash(normalized)
    end

    def ocr_candidates_snapshot(candidates)
      purchase_candidates_limit = snapshot_purchase_candidates_limit
      payment_candidates_limit = snapshot_payment_candidates_limit

      {
        store_name: safe_string(candidates[:store_name]),
        store_address: safe_string(candidates[:store_address]),
        store_address_components: sanitize_hash(candidates[:store_address_components]).presence,
        store_phone_number: safe_string(candidates[:store_phone_number]),
        purchased_at_text: safe_string(candidates[:purchased_at_text]),
        purchased_at_candidates: limited_strings(candidates[:purchased_at_candidates], purchase_candidates_limit),
        purchase_context_lines: limited_strings(candidates[:purchase_context_lines], purchase_candidates_limit),
        total_amount: safe_value(candidates[:total_amount]),
        subtotal_amount: safe_value(candidates[:subtotal_amount]),
        tax_amount: safe_value(candidates[:tax_amount]),
        tax_rate: safe_value(candidates[:tax_rate]),
        payment_method_text: safe_string(candidates[:payment_method_text]),
        payment_candidates: limited_hashes(candidates[:payment_candidates], payment_candidates_limit),
        tip_amount: safe_value(candidates[:tip_amount]),
        currency_code: safe_string(candidates[:currency_code]),
        country_region: safe_string(candidates[:country_region]),
        receipt_type: safe_string(candidates[:receipt_type]),
        payments: limited_ocr_payments(candidates[:payments]),
        tax_details: limited_ocr_tax_details(candidates[:tax_details]),
        adjustment_candidates: limited_hashes(candidates[:adjustment_candidates], receipt_adjustments_snapshot_limit),
        items: limited_ocr_items(candidates[:items]),
        review_reasons: limited_strings(candidates[:review_reasons], snapshot_review_reasons_limit),
        confidence_summary: sanitized_confidence_summary(candidates[:confidence_summary])
      }.compact
    end

    def ocr_candidate_counts(candidates, snapshot)
      {
        items: count_metadata(candidates[:items], snapshot[:items]),
        payments: count_metadata(candidates[:payments], snapshot[:payments]),
        tax_details: count_metadata(candidates[:tax_details], snapshot[:tax_details]),
        adjustment_candidates: count_metadata(candidates[:adjustment_candidates], snapshot[:adjustment_candidates])
      }
    end

    def ai_normalized_attribute_counts(result, receipt_items_snapshot:, receipt_adjustments_snapshot:)
      {
        receipt_items_attributes: count_metadata(result[:receipt_items_attributes], receipt_items_snapshot),
        receipt_adjustments_attributes: count_metadata(result[:receipt_adjustments_attributes], receipt_adjustments_snapshot)
      }
    end

    def count_metadata(actual_values, snapshot_values)
      {
        actual_count: Array(actual_values).size,
        snapshot_count: Array(snapshot_values).size
      }
    end

    def ocr_meta_snapshot(value)
      meta = normalized_hash(value)

      {
        provider: safe_string(meta[:provider]),
        model_id: safe_string(meta[:model_id]),
        model: safe_string(meta[:model]),
        doc_type: safe_string(meta[:doc_type]),
        polling_metrics: sanitized_polling_metrics(meta[:polling_metrics]).presence,
        provider_error_detail: provider_error_detail_snapshot(meta[:provider_error_detail]).presence
      }.compact
    end

    def limited_ocr_items(items)
      Array(items).first(ocr_items_snapshot_limit).filter_map do |item|
        item = normalized_hash(item)
        next if item.blank?

        {
          raw_text: safe_string(item[:raw_text]),
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
          quantity_unit_code: safe_string(item[:quantity_unit_code]),
          quantity_unit: safe_string(item[:quantity_unit]),
          product_code: safe_string(item[:product_code]),
          line_total: safe_value(item[:line_total]),
          original_line_total: safe_value(item[:original_line_total]),
          discount_amount: safe_value(item[:discount_amount]),
          discount_rate: safe_value(item[:discount_rate]),
          tax_rate: safe_value(item[:tax_rate]),
          confidence: safe_value(item[:confidence])
        }.compact
      end
    end

    def limited_ocr_payments(payments)
      Array(payments).first(receipt_payments_snapshot_limit).filter_map do |payment|
        payment = normalized_hash(payment)
        next if payment.blank?

        {
          method: safe_string(payment[:method]),
          amount: safe_value(payment[:amount]),
          confidence: safe_value(payment[:confidence])
        }.compact
      end
    end

    def receipt_payments_snapshot_limit
      SystemSettings.limit_for("limits.receipt_payments_per_receipt")
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_MAX_OCR_PAYMENTS
    end

    def limited_ocr_tax_details(tax_details)
      Array(tax_details).first(receipt_tax_details_snapshot_limit).filter_map do |tax_detail|
        tax_detail = normalized_hash(tax_detail)
        next if tax_detail.blank?

        {
          description: safe_string(tax_detail[:description]),
          amount: safe_value(tax_detail[:amount]),
          rate: safe_value(tax_detail[:rate]),
          net_amount: safe_value(tax_detail[:net_amount])
        }.compact
      end
    end

    def receipt_tax_details_snapshot_limit
      SystemSettings.limit_for("limits.receipt_tax_details_per_receipt")
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_MAX_OCR_TAX_DETAILS
    end

    def normalized_receipt_attributes_snapshot(value)
      attributes = normalized_hash(value)

      {
        store_name: safe_string(attributes[:store_name]),
        store_address: safe_string(attributes[:store_address]),
        store_phone_number: safe_string(attributes[:store_phone_number]),
        purchased_at: safe_value(attributes[:purchased_at]),
        purchased_at_text: safe_string(attributes[:purchased_at_text]),
        total_amount: safe_value(attributes[:total_amount]),
        subtotal_amount: safe_value(attributes[:subtotal_amount]),
        tax_amount: safe_value(attributes[:tax_amount]),
        tax_rate: safe_value(attributes[:tax_rate]),
        tip_amount: safe_value(attributes[:tip_amount]),
        country_region: safe_string(attributes[:country_region]),
        receipt_type: safe_string(attributes[:receipt_type]),
        payment_method: safe_string(attributes[:payment_method]),
        processing_error_code: safe_string(attributes[:processing_error_code]),
        processing_error_message: safe_string(attributes[:processing_error_message]),
        ocr_completed_at: safe_value(attributes[:ocr_completed_at])
      }.compact
    end

    def limited_ai_normalized_items(items)
      Array(items).first(ai_normalized_items_snapshot_limit).filter_map do |item|
        item = normalized_hash(item)
        next if item.blank?

        {
          index: safe_value(item[:index]),
          position_index: safe_value(item[:position_index]),
          raw_text: safe_string(item[:raw_text]),
          suggested_name: safe_string(item[:suggested_name]),
          confirmed_name: safe_string(item[:confirmed_name]),
          category: safe_string(item[:category]),
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
          quantity_unit_code: safe_string(item[:quantity_unit_code]),
          quantity_unit: safe_string(item[:quantity_unit]),
          product_code: safe_string(item[:product_code]),
          tax_rate: safe_value(item[:tax_rate]),
          tax_rate_confidence: safe_value(item[:tax_rate_confidence]),
          tax_rate_reason: safe_string(item[:tax_rate_reason]),
          original_line_total: safe_value(item[:original_line_total]),
          line_total: safe_value(item[:line_total]),
          discount_amount: safe_value(item[:discount_amount]),
          discount_rate: safe_value(item[:discount_rate]),
          needs_review: item.key?(:needs_review) ? item[:needs_review] == true : nil,
          review_reasons: limited_strings(item[:review_reasons], snapshot_review_reasons_limit),
          confidence: safe_value(item[:confidence])
        }.compact
      end
    end

    def limited_ai_normalized_adjustments(adjustments)
      Array(adjustments).first(receipt_adjustments_snapshot_limit).filter_map do |adjustment|
        adjustment = normalized_hash(adjustment)
        next if adjustment.blank?

        {
          kind: safe_string(adjustment[:kind]),
          label: safe_string(adjustment[:label]),
          amount: safe_value(adjustment[:amount]),
          sign: safe_string(adjustment[:sign]),
          tax_rate: safe_value(adjustment[:tax_rate]),
          source_text: safe_string(adjustment[:source_text]),
          source_line_index: safe_value(adjustment[:source_line_index]),
          confidence: safe_value(adjustment[:confidence]),
          needs_review: adjustment.key?(:needs_review) ? adjustment[:needs_review] == true : nil,
          review_reasons: limited_strings(adjustment[:review_reasons], snapshot_review_reasons_limit),
          position_index: safe_value(adjustment[:position_index])
        }.compact
      end
    end

    def ai_normalized_meta_snapshot(value)
      meta = normalized_hash(value)

      {
        provider: safe_string(meta[:provider]),
        model: safe_string(meta[:model]),
        primary_provider: safe_string(meta[:primary_provider]),
        fallback_provider: safe_string(meta[:fallback_provider]),
        fallback_used: meta[:fallback_used] == true,
        primary_error_code: safe_string(meta[:primary_error_code]),
        fallback_error_code: safe_string(meta[:fallback_error_code]),
        final_provider: safe_string(meta[:final_provider]),
        primary_error_detail: provider_error_detail_snapshot(meta[:primary_error_detail]).presence,
        fallback_error_detail: provider_error_detail_snapshot(meta[:fallback_error_detail]).presence,
        final_error_detail: provider_error_detail_snapshot(meta[:final_error_detail]).presence,
        metrics: sanitized_ai_metrics(meta[:metrics]).presence,
        document_type: safe_string(meta[:document_type]),
        rejection_reason: safe_string(meta[:rejection_reason]),
        is_receipt_confidence: safe_value(meta[:is_receipt_confidence])
      }.compact
    end

    def provider_error_detail_snapshot(value)
      detail = normalized_hash(value)
      return {} if detail.blank?

      ExternalServices.error_detail(
        service: detail[:service],
        provider: detail[:provider],
        phase: detail[:phase],
        http_status: detail[:http_status],
        provider_error_code: detail[:provider_error_code],
        provider_error_type: detail[:provider_error_type],
        provider_message_safe: detail[:provider_message_safe],
        request_id: detail[:request_id],
        region: detail[:region],
        retry_after: detail[:retry_after],
        latency_ms: detail[:latency_ms],
        poll_count: detail[:poll_count],
        model: detail[:model],
        rate_limited: detail[:rate_limited],
        quota_exceeded: detail[:quota_exceeded],
        auth_error: detail[:auth_error],
        disabled: detail[:disabled],
        source: detail[:source],
        reason: detail[:reason]
      )
    end

    def ocr_items_snapshot_limit
      @ocr_items_snapshot_limit ||= self.class.snapshot_ocr_items_max
    end

    def ai_normalized_items_snapshot_limit
      @ai_normalized_items_snapshot_limit ||= self.class.snapshot_ai_normalized_items_max
    end

    def receipt_adjustments_snapshot_limit
      @receipt_adjustments_snapshot_limit ||= ReceiptAdjustment.per_receipt_limit
    end

    def snapshot_ocr_lines_limit
      @snapshot_ocr_lines_limit ||= self.class.snapshot_ocr_lines_max
    end

    def snapshot_ai_input_full_context_lines_limit
      @snapshot_ai_input_full_context_lines_limit ||= self.class.snapshot_ai_input_full_context_lines_max
    end

    def snapshot_ai_input_adjustment_context_lines_limit
      @snapshot_ai_input_adjustment_context_lines_limit ||= self.class.snapshot_ai_input_adjustment_context_lines_max
    end

    def snapshot_ai_input_filtered_content_limit
      @snapshot_ai_input_filtered_content_limit ||= self.class.snapshot_ai_input_filtered_content_max_bytes
    end

    def snapshot_string_limit
      @snapshot_string_limit ||= self.class.snapshot_string_max_bytes
    end

    def snapshot_ai_input_items_limit
      @snapshot_ai_input_items_limit ||= self.class.snapshot_ai_input_items_max
    end

    def snapshot_store_candidates_limit
      @snapshot_store_candidates_limit ||= self.class.snapshot_store_candidates_max
    end

    def snapshot_purchase_candidates_limit
      @snapshot_purchase_candidates_limit ||= self.class.snapshot_purchase_candidates_max
    end

    def snapshot_payment_candidates_limit
      @snapshot_payment_candidates_limit ||= self.class.snapshot_payment_candidates_max
    end

    def snapshot_tax_details_limit
      @snapshot_tax_details_limit ||= self.class.snapshot_tax_details_max
    end

    def snapshot_review_reasons_limit
      @snapshot_review_reasons_limit ||= self.class.snapshot_review_reasons_max
    end

    def store_snapshot(value)
      store = normalized_hash(value)
      store_candidates_limit = snapshot_store_candidates_limit

      {
        store_name: safe_string(store[:store_name]),
        store_address: safe_string(store[:store_address]),
        store_phone_number: safe_string(store[:store_phone_number]),
        customer_facing_store_candidates: limited_strings(store[:customer_facing_store_candidates], store_candidates_limit),
        store_candidates: limited_strings(store[:store_candidates], store_candidates_limit),
        operator_candidates: limited_strings(store[:operator_candidates], store_candidates_limit),
        branch_name_candidates: limited_strings(store[:branch_name_candidates], store_candidates_limit),
        address_candidates: limited_strings(store[:address_candidates], store_candidates_limit)
      }.compact
    end

    def purchase_snapshot(value)
      purchase = normalized_hash(value)
      purchase_candidates_limit = snapshot_purchase_candidates_limit

      {
        purchased_at_text: safe_string(purchase[:purchased_at_text]),
        purchased_at_candidates: limited_strings(purchase[:purchased_at_candidates], purchase_candidates_limit),
        purchase_context_lines: limited_strings(purchase[:purchase_context_lines], purchase_candidates_limit)
      }.compact
    end

    def payment_snapshot(value)
      payment = normalized_hash(value)
      payment_candidates_limit = snapshot_payment_candidates_limit

      {
        payment_method: safe_string(payment[:payment_method]),
        payment_method_text: safe_string(payment[:payment_method_text]),
        payment_candidates: limited_hashes(payment[:payment_candidates], payment_candidates_limit),
        payment_context_lines: limited_strings(payment[:payment_context_lines], payment_candidates_limit)
      }.compact
    end

    def tax_snapshot(value)
      tax = normalized_hash(value)
      tax_details_limit = snapshot_tax_details_limit

      {
        tax_rate: safe_value(tax[:tax_rate]),
        tax_amount: safe_value(tax[:tax_amount]),
        total_amount: safe_value(tax[:total_amount]),
        tax_details: limited_hashes(tax[:tax_details], tax_details_limit),
        tax_context_lines: limited_strings(tax[:tax_context_lines], tax_details_limit)
      }.compact
    end

    def ai_input_meta_snapshot(value)
      meta = normalized_hash(value)

      {
        ocr_provider: safe_string(meta[:ocr_provider]),
        ocr_model: safe_string(meta[:ocr_model]),
        country_region: safe_string(meta[:country_region]),
        raw_text_length: safe_value(meta[:raw_text_length]),
        line_count: safe_value(meta[:line_count]),
        item_count: safe_value(meta[:item_count]),
        confidence_summary: sanitized_confidence_summary(meta[:confidence_summary]),
        ai_name_completion_enabled: meta[:ai_name_completion_enabled] == true
      }.compact
    end

    def limited_items(items)
      Array(items).first(snapshot_ai_input_items_limit).filter_map do |item|
        item = normalized_hash(item)
        next if item.blank?

        {
          index: safe_value(item[:index]),
          raw_text: safe_string(item[:raw_text]),
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
          quantity_unit_code: safe_string(item[:quantity_unit_code]),
          quantity_unit: safe_string(item[:quantity_unit]),
          line_total: safe_value(item[:line_total]),
          tax_rate: safe_value(item[:tax_rate]),
          product_code: safe_string(item[:product_code]),
          confidence: safe_value(item[:confidence])
        }.compact
      end
    end

    def limited_adjustment_context_lines(lines)
      limited_context_lines(lines, snapshot_ai_input_adjustment_context_lines_limit)
    end

    def limited_context_lines(lines, max)
      Array(lines).first(max).filter_map do |line|
        line = normalized_hash(line)
        next if line.blank?

        {
          index: safe_value(line[:index]),
          text: safe_string(line[:text]),
          previous_text: safe_string(line[:previous_text]),
          next_text: safe_string(line[:next_text])
        }.compact
      end
    end

    def amount_snapshot(receipt, receipt_attrs)
      {
        total_amount: safe_value(receipt_attrs[:total_amount] || receipt&.total_amount),
        subtotal_amount: safe_value(receipt_attrs[:subtotal_amount] || receipt&.subtotal_amount),
        tax_amount: safe_value(receipt_attrs[:tax_amount] || receipt&.tax_amount)
      }.compact
    end

    def sanitized_confidence_summary(value)
      summary = normalized_hash(value)

      summary.each_with_object({}) do |(key, child_value), memo|
        memo[key.to_s] = safe_value(child_value)
      end
    end

    def sanitized_polling_metrics(value)
      metrics = normalized_hash(value)

      {
        elapsed_ms: safe_value(metrics[:elapsed_ms]),
        poll_count: safe_value(metrics[:poll_count]),
        final_status: safe_string(metrics[:final_status]),
        max_poll_count: safe_value(metrics[:max_poll_count]),
        poll_interval: safe_value(metrics[:poll_interval]),
        total_poll_sleep_ms: safe_value(metrics[:total_poll_sleep_ms]),
        max_poll_interval: safe_value(metrics[:max_poll_interval]),
        poll_backoff_factor: safe_value(metrics[:poll_backoff_factor]),
        reached_max_poll: safe_value(metrics[:reached_max_poll]),
        retry_after_used: safe_value(metrics[:retry_after_used]),
        retry_count: safe_value(metrics[:retry_count])
      }.compact
    end

    def sanitized_ai_metrics(value)
      Ai::ProviderMetrics.build(value)
    end

    def limited_hashes(value, max)
      Array(value).first(max).filter_map do |item|
        next unless item.respond_to?(:to_h)

        sanitize_hash(normalized_hash(item))
      end
    end

    def limited_strings(value, max)
      Array(value).first(max).filter_map do |item|
        safe_string(item)
      end
    end

    def count_records(value, association)
      return Array(value).size unless value.nil?
      return association.size if association.respond_to?(:loaded?) && association.loaded?
      return association.count if association.respond_to?(:count)

      0
    end

    def sanitize_hash(value)
      normalized_hash(value).each_with_object({}) do |(key, child_value), memo|
        key = key.to_s
        next if forbidden_key?(key)

        sanitized = sanitize_value(child_value)
        memo[key] = sanitized unless sanitized.nil?
      end
    end

    def sanitize_value(value)
      case value
      when Hash
        sanitize_hash(value)
      when Array
        value.filter_map { |item| sanitize_value(item) }
      when BigDecimal
        value.to_s("F")
      when Symbol
        safe_string(value)
      when String
        safe_string(value)
      when Numeric, TrueClass, FalseClass
        value
      when Time, Date, DateTime
        value.iso8601
      else
        safe_string(value)
      end
    end

    def safe_value(value)
      case value
      when BigDecimal
        value.to_s("F")
      when Symbol
        safe_string(value)
      when String
        safe_string(value)
      when Numeric, TrueClass, FalseClass
        value
      when Time, Date, DateTime
        value.iso8601
      else
        return nil if value.nil?

        safe_string(value)
      end
    end

    def safe_string(value)
      return nil if value.nil?

      truncate_string(value.to_s, max_bytes: snapshot_string_limit)
    end

    def truncate_string(value, max_bytes:)
      text = value.to_s
      return text if text.bytesize <= max_bytes

      truncated = +""
      text.each_char do |char|
        break if truncated.bytesize + char.bytesize > max_bytes

        truncated << char
      end
      truncated
    end

    def truncated?(value, max_bytes:)
      value.to_s.bytesize > max_bytes
    end

    def normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

      {}.with_indifferent_access
    end

    def forbidden_key?(key)
      normalized = key.to_s.downcase
      EXACT_FORBIDDEN_KEYS.include?(normalized) ||
        FORBIDDEN_KEY_FRAGMENTS.any? { |forbidden| normalized.include?(forbidden) }
    end
  end
end
