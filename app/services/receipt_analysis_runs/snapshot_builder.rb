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
    MAX_OCR_ITEMS = 100
    MAX_OCR_PAYMENTS = 20
    MAX_OCR_TAX_DETAILS = 20
    MAX_OCR_ADJUSTMENT_CANDIDATES = 50
    MAX_AI_NORMALIZED_ITEMS = 100
    MAX_AI_NORMALIZED_ADJUSTMENTS = 50
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
          review_reasons: limited_strings(params[:review_reasons], MAX_REVIEW_REASONS)
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
          polling_metrics: sanitized_polling_metrics(meta[:polling_metrics]).presence
        }.compact
      )
    end

    def ocr_result_snapshot(ocr_result)
      result = normalized_hash(ocr_result)
      candidates = normalized_hash(result[:candidates])
      lines = limited_strings(result[:lines], MAX_OCR_LINES)

      sanitize_hash(
        {
          schema_version: OCR_RESULT_SCHEMA_VERSION,
          success: result[:success] == true,
          lines: lines,
          candidates: ocr_candidates_snapshot(candidates),
          error_code: safe_string(result[:error_code]),
          meta: ocr_meta_snapshot(result[:meta]),
          truncated: {
            lines: Array(result[:lines]).size > MAX_OCR_LINES,
            items: Array(candidates[:items]).size > MAX_OCR_ITEMS,
            payments: Array(candidates[:payments]).size > MAX_OCR_PAYMENTS,
            tax_details: Array(candidates[:tax_details]).size > MAX_OCR_TAX_DETAILS
          }
        }.compact
      )
    end

    def ai_input_snapshot(ai_input)
      input = normalized_hash(ai_input)

      filtered_content = truncate_string(input[:filtered_content], max_bytes: FILTERED_CONTENT_MAX_BYTES)
      items = limited_items(input[:items])

      sanitize_hash(
        {
          schema_version: AI_INPUT_SCHEMA_VERSION,
          prompt_schema_version: PROMPT_SCHEMA_VERSION,
          filtered_content: filtered_content,
          full_context_lines: limited_context_lines(input[:full_context_lines], MAX_FULL_CONTEXT_LINES),
          store: store_snapshot(input[:store]),
          purchase: purchase_snapshot(input[:purchase]),
          payment: payment_snapshot(input[:payment]),
          tax: tax_snapshot(input[:tax]),
          items: items,
          adjustment_context_lines: limited_adjustment_context_lines(input[:adjustment_context_lines]),
          meta: ai_input_meta_snapshot(input[:meta]),
          truncated: {
            filtered_content: truncated?(input[:filtered_content], max_bytes: FILTERED_CONTENT_MAX_BYTES),
            items: Array(input[:items]).size > MAX_ITEMS,
            full_context_lines: Array(input[:full_context_lines]).size > MAX_FULL_CONTEXT_LINES,
            adjustment_context_lines: Array(input[:adjustment_context_lines]).size > MAX_ADJUSTMENT_CONTEXT_LINES
          }
        }.compact
      )
    end

    def ai_normalized_result_snapshot(ai_result)
      result = normalized_hash(ai_result)

      sanitize_hash(
        {
          schema_version: AI_NORMALIZED_RESULT_SCHEMA_VERSION,
          success: result[:success] == true,
          error_code: safe_string(result[:error_code]),
          needs_review: result[:needs_review] == true,
          review_reasons: limited_strings(result[:review_reasons], MAX_REVIEW_REASONS),
          receipt_attributes: normalized_receipt_attributes_snapshot(result[:receipt_attributes]),
          receipt_items_attributes: limited_ai_normalized_items(result[:receipt_items_attributes]),
          receipt_adjustments_attributes: limited_ai_normalized_adjustments(result[:receipt_adjustments_attributes]),
          meta: ai_normalized_meta_snapshot(result[:meta]),
          truncated: {
            receipt_items_attributes: Array(result[:receipt_items_attributes]).size > MAX_AI_NORMALIZED_ITEMS,
            receipt_adjustments_attributes: Array(result[:receipt_adjustments_attributes]).size > MAX_AI_NORMALIZED_ADJUSTMENTS,
            review_reasons: Array(result[:review_reasons]).size > MAX_REVIEW_REASONS
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
          review_reasons: limited_strings(result[:review_reasons], MAX_REVIEW_REASONS),
          provider: safe_string(meta[:provider] || meta[:primary_provider]),
          model: safe_string(meta[:model]),
          fallback_provider: safe_string(meta[:fallback_provider]),
          fallback_used: meta[:fallback_used] == true,
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
          review_reasons: limited_strings(receipt_attrs[:review_reasons] || receipt&.review_reasons, MAX_REVIEW_REASONS),
          item_count: count_records(items_attributes, receipt&.receipt_items),
          payment_count: count_records(payments_attributes, receipt&.receipt_payments),
          tax_detail_count: count_records(tax_details_attributes, receipt&.receipt_tax_details),
          adjustment_count: count_records(adjustments_attributes, receipt&.receipt_adjustments),
          amount: amount_snapshot(receipt, receipt_attrs),
          amount_mismatch_codes: limited_strings(amount[:mismatch_codes], MAX_REVIEW_REASONS),
          amount_blocking_mismatch_codes: limited_strings(amount[:blocking_mismatch_codes], MAX_REVIEW_REASONS),
          amount_warning_mismatch_codes: limited_strings(amount[:warning_mismatch_codes], MAX_REVIEW_REASONS)
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
      {
        store_name: safe_string(candidates[:store_name]),
        store_address: safe_string(candidates[:store_address]),
        store_address_components: sanitize_hash(candidates[:store_address_components]).presence,
        store_phone_number: safe_string(candidates[:store_phone_number]),
        purchased_at_text: safe_string(candidates[:purchased_at_text]),
        purchased_at_candidates: limited_strings(candidates[:purchased_at_candidates], MAX_PURCHASED_AT_CANDIDATES),
        purchase_context_lines: limited_strings(candidates[:purchase_context_lines], MAX_PURCHASED_AT_CANDIDATES),
        total_amount: safe_value(candidates[:total_amount]),
        subtotal_amount: safe_value(candidates[:subtotal_amount]),
        tax_amount: safe_value(candidates[:tax_amount]),
        tax_rate: safe_value(candidates[:tax_rate]),
        payment_method_text: safe_string(candidates[:payment_method_text]),
        payment_candidates: limited_hashes(candidates[:payment_candidates], MAX_PAYMENT_CANDIDATES),
        tip_amount: safe_value(candidates[:tip_amount]),
        currency_code: safe_string(candidates[:currency_code]),
        country_region: safe_string(candidates[:country_region]),
        receipt_type: safe_string(candidates[:receipt_type]),
        payments: limited_ocr_payments(candidates[:payments]),
        tax_details: limited_ocr_tax_details(candidates[:tax_details]),
        adjustment_candidates: limited_hashes(candidates[:adjustment_candidates], MAX_OCR_ADJUSTMENT_CANDIDATES),
        items: limited_ocr_items(candidates[:items]),
        review_reasons: limited_strings(candidates[:review_reasons], MAX_REVIEW_REASONS),
        confidence_summary: sanitized_confidence_summary(candidates[:confidence_summary])
      }.compact
    end

    def ocr_meta_snapshot(value)
      meta = normalized_hash(value)

      {
        provider: safe_string(meta[:provider]),
        model_id: safe_string(meta[:model_id]),
        model: safe_string(meta[:model]),
        doc_type: safe_string(meta[:doc_type]),
        polling_metrics: sanitized_polling_metrics(meta[:polling_metrics]).presence
      }.compact
    end

    def limited_ocr_items(items)
      Array(items).first(MAX_OCR_ITEMS).filter_map do |item|
        item = normalized_hash(item)
        next if item.blank?

        {
          raw_text: safe_string(item[:raw_text]),
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
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
      Array(payments).first(MAX_OCR_PAYMENTS).filter_map do |payment|
        payment = normalized_hash(payment)
        next if payment.blank?

        {
          method: safe_string(payment[:method]),
          amount: safe_value(payment[:amount]),
          confidence: safe_value(payment[:confidence])
        }.compact
      end
    end

    def limited_ocr_tax_details(tax_details)
      Array(tax_details).first(MAX_OCR_TAX_DETAILS).filter_map do |tax_detail|
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
      Array(items).first(MAX_AI_NORMALIZED_ITEMS).filter_map do |item|
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
          review_reasons: limited_strings(item[:review_reasons], MAX_REVIEW_REASONS),
          confidence: safe_value(item[:confidence])
        }.compact
      end
    end

    def limited_ai_normalized_adjustments(adjustments)
      Array(adjustments).first(MAX_AI_NORMALIZED_ADJUSTMENTS).filter_map do |adjustment|
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
          review_reasons: limited_strings(adjustment[:review_reasons], MAX_REVIEW_REASONS),
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
        document_type: safe_string(meta[:document_type]),
        rejection_reason: safe_string(meta[:rejection_reason]),
        is_receipt_confidence: safe_value(meta[:is_receipt_confidence])
      }.compact
    end

    def store_snapshot(value)
      store = normalized_hash(value)

      {
        store_name: safe_string(store[:store_name]),
        store_address: safe_string(store[:store_address]),
        store_phone_number: safe_string(store[:store_phone_number]),
        store_candidates: limited_strings(store[:store_candidates], MAX_STORE_CANDIDATES),
        branch_name_candidates: limited_strings(store[:branch_name_candidates], MAX_STORE_CANDIDATES),
        address_candidates: limited_strings(store[:address_candidates], MAX_STORE_CANDIDATES)
      }.compact
    end

    def purchase_snapshot(value)
      purchase = normalized_hash(value)

      {
        purchased_at_text: safe_string(purchase[:purchased_at_text]),
        purchased_at_candidates: limited_strings(purchase[:purchased_at_candidates], MAX_PURCHASED_AT_CANDIDATES),
        purchase_context_lines: limited_strings(purchase[:purchase_context_lines], MAX_PURCHASED_AT_CANDIDATES)
      }.compact
    end

    def payment_snapshot(value)
      payment = normalized_hash(value)

      {
        payment_method: safe_string(payment[:payment_method]),
        payment_method_text: safe_string(payment[:payment_method_text]),
        payment_candidates: limited_hashes(payment[:payment_candidates], MAX_PAYMENT_CANDIDATES),
        payment_context_lines: limited_strings(payment[:payment_context_lines], MAX_PAYMENT_CANDIDATES)
      }.compact
    end

    def tax_snapshot(value)
      tax = normalized_hash(value)

      {
        tax_rate: safe_value(tax[:tax_rate]),
        tax_amount: safe_value(tax[:tax_amount]),
        total_amount: safe_value(tax[:total_amount]),
        tax_details: limited_hashes(tax[:tax_details], MAX_TAX_DETAILS),
        tax_context_lines: limited_strings(tax[:tax_context_lines], MAX_TAX_DETAILS)
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
      Array(items).first(MAX_ITEMS).filter_map do |item|
        item = normalized_hash(item)
        next if item.blank?

        {
          index: safe_value(item[:index]),
          raw_text: safe_string(item[:raw_text]),
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
          quantity_unit: safe_string(item[:quantity_unit]),
          line_total: safe_value(item[:line_total]),
          tax_rate: safe_value(item[:tax_rate]),
          product_code: safe_string(item[:product_code]),
          confidence: safe_value(item[:confidence])
        }.compact
      end
    end

    def limited_adjustment_context_lines(lines)
      limited_context_lines(lines, MAX_ADJUSTMENT_CONTEXT_LINES)
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

      truncate_string(value.to_s, max_bytes: STRING_MAX_BYTES)
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
