module Receipts::Processing::Runs
  class SnapshotBuilder
    OCR_SUMMARY_SCHEMA_VERSION = "receipt_analysis_run_ocr_summary_v1"
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"
    AI_INPUT_SCHEMA_VERSION = "receipt_analysis_run_ai_input_v1"
    AI_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ai_result_v1"
    AI_NORMALIZED_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ai_normalized_result_v1"
    FINALIZE_DECISION_SCHEMA_VERSION = Receipts::Processing::Contracts::FinalizeDecision::SCHEMA_VERSION
    BUILD_PARAMS_SCHEMA_VERSION = "receipt_analysis_run_build_params_v1"
    FINAL_RESULT_SCHEMA_VERSION = "receipt_analysis_run_final_result_v1"
    PROMPT_SCHEMA_VERSION = "recify_receipt_analysis_v1"

    FINALIZE_STRATEGIES = Receipts::Processing::Contracts::FinalizeDecision::STRATEGIES
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
    MAX_REFERENCE_PRICING_CANDIDATES = 100
    MAX_ITEM_CALCULATION_MODE_CANDIDATES = Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_SETS
    ITEM_CALCULATION_MODE_ITEM_IDENTITY_MAX_BYTES = Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_ID_BYTES
    MAX_REFERENCE_PRICING_ITEM_INDEX = MAX_REFERENCE_PRICING_CANDIDATES - 1
    MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET = 10_000_000
    MAX_REFERENCE_PRICING_PROJECTED_AMOUNT = 999_999_999
    QUANTITY_UNIT_RAW_MAX_BYTES = 64
    QUANTITY_UNIT_STATUSES = %w[known blank unknown].freeze
    REFERENCE_PRICING_VALIDATION_STATES = %w[valid missing ambiguous unsupported].freeze
    MAX_REFERENCE_PRICING_REJECTION_REASONS = 8
    REFERENCE_PRICING_REJECTION_REASONS = %w[
      ambiguous_reference_expression
      ambiguous_purchased_quantity
      ambiguous_tax_inclusion
      evidence_outside_item
      incompatible_unit_dimension
      insufficient_component_evidence
      invalid_purchased_quantity
      invalid_reference_price
      invalid_reference_quantity
      missing_purchased_quantity
      missing_purchased_unit
      missing_reference_price
      missing_reference_quantity
      missing_reference_unit
      purchased_quantity_out_of_bounds
      reference_price_out_of_bounds
      reference_quantity_out_of_bounds
      unsupported_purchased_unit
      unsupported_reference_unit
    ].freeze
    REFERENCE_PRICING_UNIT_STATUSES = %w[known blank unknown].freeze
    REFERENCE_PRICING_UNIT_RAW_MAX_BYTES = 64
    REFERENCE_PRICING_ORIGINS = %w[explicit implicit_per_unit].freeze
    REFERENCE_PRICE_TAX_INCLUSIONS = %w[gross net unknown].freeze
    REFERENCE_PRICING_ROUNDING_MATCHES = %w[floor half_up ceil].freeze
    REFERENCE_PRICING_CANDIDATE_ID_MAX_BYTES = 128
    REFERENCE_PRICING_EXACT_NUMBER_MAX_BYTES = 64
    REFERENCE_PRICING_SOURCE_FIELD_PATH_MAX_BYTES = 256
    REFERENCE_PRICING_DESTINATION_ID_MAX_BYTES = 160
    REFERENCE_PRICING_SOURCE_PROVIDERS = %w[azure_structured].freeze
    REFERENCE_PRICING_LINE_SOURCE_PROVIDERS = %w[azure_line_group].freeze
    REFERENCE_PRICING_SOURCE_KINDS = %w[azure_line_group].freeze
    REFERENCE_PRICING_STRING_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
    REFERENCE_PRICING_LINE_GROUP_PROVIDER_MODELS = %w[prebuilt-receipt].freeze
    REFERENCE_PRICING_LINE_GROUP_API_VERSIONS = %w[2024-11-30].freeze
    REFERENCE_PRICING_LINE_GROUP_VALIDATION_CONTRACTS = %w[azure_line_group_v1].freeze
    REFERENCE_PRICING_LINE_GROUP_PROFILE_COUNTRY_CODES = %w[JPN].freeze
    REFERENCE_PRICING_DESTINATION_CONTRACTS = %w[azure_line_group_destination_v1].freeze
    REFERENCE_PRICING_DESTINATION_KINDS = %w[reference_line_prefix].freeze
    MAX_REFERENCE_PRICING_DESTINATION_GRAPHEMES = 24
    MAX_REFERENCE_PRICING_DESTINATION_WORDS = 8
    REFERENCE_PRICING_TAX_WORD_COUNT = 2
    MAX_REFERENCE_PRICING_WORD_INDEX = 4_799
    MAX_REFERENCE_PRICING_PAGE_INDEX = 99
    MAX_REFERENCE_PRICING_LINE_INDEX = MAX_OCR_LINES - 1
    REFERENCE_PRICING_SOURCE_FIELD_PATH_PATTERN = /\Adocuments\[\d+\]\.fields\.Items\[\d+\](?:\.[A-Za-z][A-Za-z0-9]*)?\z/
    REFERENCE_PRICING_LINE_SOURCE_FIELD_PATH_PATTERN = /\Apages\[\d+\]\.lines\[\d+\]\z/
    REFERENCE_PRICING_WORD_SOURCE_FIELD_PATH_PATTERN = /\Apages\[\d+\]\.words\[\d+\]\z/
    SNAPSHOT_CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F]/.freeze
    OWNERSHIP_CONTRACT_KEYS = %i[
      schema_version
      duplicate_source_owner_count
      payment_source_purchase_adjustment_count
      tax_detail_source_effect_count
      unknown_purchase_tax_allocation_count
      adjustment_review_required_count
    ].freeze

    EXACT_FORBIDDEN_KEYS = (
      %w[
        access_token
        access-token
        api_key
        authorization
        azure_raw_response
        blob_key
        client_secret
        cookie
        cookies
        full_prompt
        headers
        image
        image-payload
        image_payload
        messages
        openai_raw_response
        prompt
        prompt_text
        provider_raw_response
        raw_ai_response
        raw_response
        response_body
        refresh_token
        refresh-token
        secret
        set-cookie
        set_cookie
        signed_id
        source_ref
        source_refs
        diagnostics
        system_prompt
        token
        user_prompt
      ] + SensitiveMetadataKeys::PROVIDER_DETAIL_KEYS
    ).freeze
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
          reference_pricing_candidates: build_params_reference_pricing_candidates_summary(
            params[:reference_pricing_candidates]
          ),
          ownership_contract: ownership_contract_snapshot(params[:ownership_contract]),
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
      case_preserved_lines = limited_strings(result[:case_preserved_lines], ocr_lines_limit)
      candidates_snapshot = ocr_candidates_snapshot(candidates)
      snapshot = {
        schema_version: OCR_RESULT_SCHEMA_VERSION,
        success: result[:success] == true,
        lines: lines,
        case_preserved_lines: case_preserved_lines.presence,
        candidates: candidates_snapshot,
        candidate_counts: ocr_candidate_counts(
          candidates,
          candidates_snapshot,
          stored_result: result
        ),
        error_code: safe_string(result[:error_code]),
        meta: ocr_meta_snapshot(result[:meta]),
        truncated: {
          lines: Array(result[:lines]).size > ocr_lines_limit,
          case_preserved_lines: Array(result[:case_preserved_lines]).size > ocr_lines_limit,
          items: Array(candidates[:items]).size > ocr_items_snapshot_limit,
          payments: Array(candidates[:payments]).size > receipt_payments_snapshot_limit,
          tax_details: Array(candidates[:tax_details]).size > receipt_tax_details_snapshot_limit,
          adjustment_candidates: Array(candidates[:adjustment_candidates]).size > receipt_adjustments_snapshot_limit,
          reference_pricing_candidates: reference_pricing_source_truncated?(result, candidates),
          item_calculation_mode_candidates: item_calculation_mode_source_truncated?(result, candidates)
        }
      }.compact
      snapshot[:adoption_proposals] = adoption_proposals_snapshot(result, snapshot).presence
      snapshot[:candidate_counts][:item_calculation_mode_candidates][:snapshot_count] = Array(snapshot.dig(:adoption_proposals, :item_calculation_modes)).size

      sanitize_hash(snapshot.compact)
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
      review_reasons = Array(result[:review_reasons])
      item_category_uncertain = receipt_items_snapshot.any? do |item|
        Array(item[:review_reasons] || item["review_reasons"]).include?("item_category_uncertain")
      end
      review_reasons |= [ "item_category_uncertain" ] if item_category_uncertain

      sanitize_hash(
        {
          schema_version: AI_NORMALIZED_RESULT_SCHEMA_VERSION,
          success: result[:success] == true,
          error_code: safe_string(result[:error_code]),
          needs_review: result[:needs_review] == true || item_category_uncertain,
          review_reasons: limited_strings(review_reasons, snapshot_review_reasons_limit),
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

    def ownership_contract_snapshot(value)
      contract = normalized_hash(value)

      OWNERSHIP_CONTRACT_KEYS.each_with_object({}) do |key, snapshot|
        snapshot[key] = safe_value(contract[key]) if contract.key?(key)
      end.presence
    end

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

    def build_params_reference_pricing_candidates_summary(value)
      candidates = Array(value).first(MAX_REFERENCE_PRICING_CANDIDATES)
      return nil if candidates.empty?

      state_counts = Hash.new(0)
      reason_counts = Hash.new(0)

      candidates.each do |candidate|
        normalized = normalized_hash(candidate)
        state = normalized[:validation_state].to_s
        state_counts[state] += 1 if REFERENCE_PRICING_VALIDATION_STATES.include?(state)

        reference_pricing_rejection_reasons(normalized[:rejection_reasons]).each do |reason|
          reason = reason.to_s
          reason_counts[reason] += 1
        end
      end

      {
        candidate_count: candidates.size,
        validation_state_counts: state_counts.sort.to_h,
        reason_counts: reason_counts.sort.to_h
      }
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
        reference_pricing_candidates: limited_reference_pricing_candidates(candidates[:reference_pricing_candidates]),
        items: limited_ocr_items(candidates[:items]),
        review_reasons: limited_strings(candidates[:review_reasons], snapshot_review_reasons_limit),
        confidence_summary: sanitized_confidence_summary(candidates[:confidence_summary])
      }.compact
    end

    def ocr_candidate_counts(candidates, snapshot, stored_result: nil)
      {
        items: count_metadata(candidates[:items], snapshot[:items]),
        payments: count_metadata(candidates[:payments], snapshot[:payments]),
        tax_details: count_metadata(candidates[:tax_details], snapshot[:tax_details]),
        adjustment_candidates: count_metadata(candidates[:adjustment_candidates], snapshot[:adjustment_candidates]),
        reference_pricing_candidates: reference_pricing_candidate_counts(
          candidates,
          snapshot: snapshot,
          stored_result: stored_result
        ),
        item_calculation_mode_candidates: item_calculation_mode_candidate_counts(
          candidates,
          stored_result: stored_result
        )
      }
    end

    def reference_pricing_candidate_counts(candidates, snapshot:, stored_result:)
      if stored_reference_pricing_metadata?(stored_result)
        counts = normalized_hash(stored_result[:candidate_counts])[:reference_pricing_candidates]
        counts = normalized_hash(counts)
        actual_count = counts[:actual_count]
        snapshot_count = counts[:snapshot_count]
        source_count = Array(candidates[:reference_pricing_candidates]).size
        if actual_count.is_a?(Integer) && snapshot_count.is_a?(Integer) &&
            actual_count.between?(0, MAX_OCR_ITEMS) &&
            snapshot_count.between?(0, MAX_REFERENCE_PRICING_CANDIDATES) &&
            source_count <= MAX_REFERENCE_PRICING_CANDIDATES &&
            actual_count >= snapshot_count && snapshot_count == source_count
          return { actual_count: actual_count, snapshot_count: snapshot_count }
        end

        return { actual_count: 0, snapshot_count: 0 }
      end

      count_metadata(candidates[:reference_pricing_candidates], snapshot[:reference_pricing_candidates])
    end

    def reference_pricing_source_truncated?(result, candidates)
      if stored_reference_pricing_metadata?(result)
        source_count = Array(candidates[:reference_pricing_candidates]).size
        return true if source_count > MAX_REFERENCE_PRICING_CANDIDATES

        counts = normalized_hash(normalized_hash(result[:candidate_counts])[:reference_pricing_candidates])
        actual_count = counts[:actual_count]
        snapshot_count = counts[:snapshot_count]
        return true unless actual_count.is_a?(Integer) && snapshot_count.is_a?(Integer)
        return true unless actual_count.between?(0, MAX_OCR_ITEMS)
        return true unless snapshot_count.between?(0, MAX_REFERENCE_PRICING_CANDIDATES)
        return true unless actual_count >= snapshot_count && snapshot_count == source_count

        truncated = normalized_hash(result[:truncated])
        return true unless truncated.key?(:reference_pricing_candidates)

        return true if truncated[:reference_pricing_candidates] != false

        return actual_count != snapshot_count
      end

      Array(candidates[:reference_pricing_candidates]).size > MAX_REFERENCE_PRICING_CANDIDATES
    end

    def stored_reference_pricing_metadata?(result)
      return false unless result.is_a?(Hash)
      return false unless result[:schema_version].to_s == OCR_RESULT_SCHEMA_VERSION

      normalized_hash(result[:candidate_counts]).key?(:reference_pricing_candidates) ||
        normalized_hash(result[:truncated]).key?(:reference_pricing_candidates)
    end

    def item_calculation_mode_candidate_counts(candidates, stored_result:)
      if stored_item_calculation_mode_metadata?(stored_result)
        stored = normalized_hash(stored_result[:candidate_counts])[:item_calculation_mode_candidates]
        counts = normalized_hash(stored)
        actual_count = counts[:actual_count]
        snapshot_count = counts[:snapshot_count]
        if actual_count.is_a?(Integer) && snapshot_count.is_a?(Integer) &&
            actual_count.between?(0, MAX_OCR_ITEMS) &&
            snapshot_count.between?(0, MAX_ITEM_CALCULATION_MODE_CANDIDATES)
          return { actual_count: actual_count, snapshot_count: snapshot_count }
        end

        return { actual_count: 0, snapshot_count: 0 }
      end

      values = Array(candidates[:item_calculation_mode_candidates])
      count_metadata(values, values.first(MAX_ITEM_CALCULATION_MODE_CANDIDATES))
    end

    def item_calculation_mode_source_truncated?(result, candidates)
      if stored_item_calculation_mode_metadata?(result)
        truncated = normalized_hash(result[:truncated])
        return true unless truncated.key?(:item_calculation_mode_candidates)

        return truncated[:item_calculation_mode_candidates] != false
      end

      candidates[:item_calculation_mode_source_truncated] == true ||
        Array(candidates[:item_calculation_mode_candidates]).size > MAX_ITEM_CALCULATION_MODE_CANDIDATES
    end

    def stored_item_calculation_mode_metadata?(result)
      return false unless result.is_a?(Hash)
      return false unless result[:schema_version].to_s == OCR_RESULT_SCHEMA_VERSION

      normalized_hash(result[:candidate_counts]).key?(:item_calculation_mode_candidates) ||
        normalized_hash(result[:truncated]).key?(:item_calculation_mode_candidates) ||
        normalized_hash(result[:adoption_proposals]).key?(:item_calculation_modes)
    end

    def adoption_proposals_snapshot(result, ocr_snapshot)
      proposals = reference_pricing_adoption_proposals_snapshot(result, ocr_snapshot) || {}
      item_calculation_modes = item_calculation_mode_proposals_snapshot(result, ocr_snapshot)
      proposals[:item_calculation_modes] = item_calculation_modes if item_calculation_modes.present?
      proposals
    end

    def item_calculation_mode_proposals_snapshot(result, ocr_snapshot)
      if result.key?(:schema_version)
        return nil unless result[:schema_version].to_s == OCR_RESULT_SCHEMA_VERSION

        stored = normalized_hash(result[:adoption_proposals])[:item_calculation_modes]
        Receipts::Processing::Contracts::ItemCalculationModeProposalSet.from_snapshot(
          stored,
          ocr_snapshot: ocr_snapshot
        )
      else
        Receipts::Processing::Contracts::ItemCalculationModeProposalSet.build_all(
          candidates: Array(normalized_hash(result[:candidates])[:item_calculation_mode_candidates]),
          ocr_snapshot: ocr_snapshot
        )
      end
    end

    def limited_reference_pricing_candidates(value)
      Array(value).first(MAX_REFERENCE_PRICING_CANDIDATES).filter_map do |candidate|
        reference_pricing_candidate_snapshot(candidate)
      end
    end

    def reference_pricing_adoption_proposals_snapshot(result, ocr_snapshot)
      proposal = if result.key?(:schema_version)
        return nil unless result[:schema_version].to_s == OCR_RESULT_SCHEMA_VERSION

        stored = normalized_hash(result[:adoption_proposals])[:reference_pricing]
        Receipts::Processing::Contracts::ReferencePricingAdoptionProposal.from_snapshot(
          stored,
          ocr_snapshot:
        )
      else
        candidates = Array(normalized_hash(result[:candidates])[:reference_pricing_candidates])
        return nil unless candidates.one?

        Receipts::Processing::Contracts::ReferencePricingAdoptionProposal.build(
          candidate: candidates.sole,
          ocr_snapshot:,
          source_case_preserved_lines: result[:case_preserved_lines]
        )
      end
      return nil if proposal.nil?

      { reference_pricing: proposal }
    end

    def reference_pricing_candidate_snapshot(value)
      candidate = normalized_hash(value)
      return nil if candidate.blank?

      source_kind = enum_string(candidate[:source_kind], REFERENCE_PRICING_SOURCE_KINDS)
      line_group = source_kind == "azure_line_group"
      return nil if line_group && (
        normalized_hash(candidate[:printed_line_total]).present? ||
        normalized_hash(candidate[:corroboration]).present?
      )

      snapshot = {
        candidate_id: bounded_string(
          candidate[:candidate_id],
          max_bytes: REFERENCE_PRICING_CANDIDATE_ID_MAX_BYTES,
          pattern: line_group ?
            /\Aazure_line_group_p\d+_l\d+_l\d+_reference_pricing\z/ :
            /\Aazure_items_\d+_reference_pricing\z/
        ),
        source_kind: source_kind,
        item_index: line_group ? nil : bounded_non_negative_integer(
          candidate[:item_index],
          maximum: MAX_REFERENCE_PRICING_ITEM_INDEX
        ),
        page_index: line_group ? bounded_non_negative_integer(
          candidate[:page_index],
          maximum: MAX_REFERENCE_PRICING_PAGE_INDEX
        ) : nil,
        reference_line_index: line_group ? bounded_non_negative_integer(
          candidate[:reference_line_index],
          maximum: MAX_REFERENCE_PRICING_LINE_INDEX
        ) : nil,
        purchased_quantity_line_index: line_group ? bounded_non_negative_integer(
          candidate[:purchased_quantity_line_index],
          maximum: MAX_REFERENCE_PRICING_LINE_INDEX
        ) : nil,
        string_index_type: line_group ? enum_string(
          candidate[:string_index_type],
          REFERENCE_PRICING_STRING_INDEX_TYPES
        ) : nil,
        provider_model_id: line_group ? enum_string(
          candidate[:provider_model_id],
          REFERENCE_PRICING_LINE_GROUP_PROVIDER_MODELS
        ) : nil,
        provider_api_version: line_group ? enum_string(
          candidate[:provider_api_version],
          REFERENCE_PRICING_LINE_GROUP_API_VERSIONS
        ) : nil,
        validation_contract_version: line_group ? enum_string(
          candidate[:validation_contract_version],
          REFERENCE_PRICING_LINE_GROUP_VALIDATION_CONTRACTS
        ) : nil,
        analysis_profile_country_code: line_group ? enum_string(
          candidate[:analysis_profile_country_code],
          REFERENCE_PRICING_LINE_GROUP_PROFILE_COUNTRY_CODES
        ) : nil,
        block_provider_span_start: line_group ? bounded_non_negative_integer(
          candidate[:block_provider_span_start],
          maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
        ) : nil,
        block_provider_span_end: line_group ? bounded_non_negative_integer(
          candidate[:block_provider_span_end],
          maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
        ) : nil,
        destination_item_identity: line_group ? reference_pricing_destination_snapshot(
          candidate[:destination_item_identity],
          index_type: candidate[:string_index_type]
        ).presence : nil,
        validation_state: enum_string(candidate[:validation_state], REFERENCE_PRICING_VALIDATION_STATES),
        rejection_reasons: reference_pricing_rejection_reasons(candidate[:rejection_reasons]),
        reference_price: line_group ? reference_pricing_line_component_snapshot(
          candidate[:reference_price],
          source_kind:
        ).presence : reference_price_snapshot(candidate[:reference_price], source_kind:).presence,
        reference_quantity: line_group ? reference_pricing_line_component_snapshot(
          candidate[:reference_quantity],
          source_kind:
        ).presence : reference_quantity_snapshot(candidate[:reference_quantity], source_kind:).presence,
        purchased_quantity: line_group ? reference_pricing_line_component_snapshot(
          candidate[:purchased_quantity],
          source_kind:
        ).presence : purchased_quantity_snapshot(candidate[:purchased_quantity], source_kind:).presence,
        reference_price_tax_inclusion: enum_string(
          candidate[:reference_price_tax_inclusion],
          REFERENCE_PRICE_TAX_INCLUSIONS
        ),
        tax_inclusion_evidence: reference_pricing_evidence_snapshot(
          candidate[:tax_inclusion_evidence],
          source_kind:
        ).presence,
        printed_line_total: line_group ? nil : printed_line_total_snapshot(
          candidate[:printed_line_total],
          source_kind:
        ).presence,
        corroboration: line_group ? nil : reference_pricing_corroboration_snapshot(
          candidate[:corroboration]
        ).presence,
        summary_total_corroboration: line_group ? reference_pricing_summary_corroboration_snapshot(
          candidate[:summary_total_corroboration]
        ).presence : nil
      }.compact

      return unless !line_group || valid_line_group_candidate_snapshot?(snapshot)

      snapshot
    end

    def reference_pricing_line_component_snapshot(value, source_kind:)
      component = normalized_hash(value)
      return {} if component.blank?

      {
        evidence: reference_pricing_evidence_snapshot(component[:evidence], source_kind:).presence
      }.compact
    end

    def reference_price_snapshot(value, source_kind: nil)
      component = normalized_hash(value)
      return {} if component.blank?

      {
        amount: exact_decimal_string(component[:amount]),
        evidence: reference_pricing_evidence_snapshot(component[:evidence], source_kind:).presence
      }.compact
    end

    def reference_quantity_snapshot(value, source_kind: nil)
      component = normalized_hash(value)
      return {} if component.blank?
      unit_status = enum_string(component[:unit_status], REFERENCE_PRICING_UNIT_STATUSES)

      {
        amount: exact_decimal_string(component[:amount]),
        unit_code: enum_string(component[:unit_code], ReceiptQuantityUnit.allowed_codes),
        unit_status: unit_status,
        unit_raw: reference_pricing_unit_raw(component[:unit_raw], status: unit_status),
        origin: enum_string(component[:origin], REFERENCE_PRICING_ORIGINS),
        evidence: reference_pricing_evidence_snapshot(component[:evidence], source_kind:).presence
      }.compact
    end

    def purchased_quantity_snapshot(value, source_kind: nil)
      component = normalized_hash(value)
      return {} if component.blank?
      unit_status = enum_string(component[:unit_status], REFERENCE_PRICING_UNIT_STATUSES)

      {
        amount: exact_decimal_string(component[:amount]),
        unit_code: enum_string(component[:unit_code], ReceiptQuantityUnit.allowed_codes),
        unit_status: unit_status,
        unit_raw: reference_pricing_unit_raw(component[:unit_raw], status: unit_status),
        evidence: reference_pricing_evidence_snapshot(component[:evidence], source_kind:).presence
      }.compact
    end

    def reference_pricing_unit_raw(value, status:)
      return nil unless status == "unknown"
      return nil unless safe_utf8_string?(value)

      truncate_string(value, max_bytes: REFERENCE_PRICING_UNIT_RAW_MAX_BYTES).presence
    end

    def printed_line_total_snapshot(value, source_kind: nil)
      component = normalized_hash(value)
      return {} if component.blank?

      {
        amount: exact_decimal_string(component[:amount]),
        evidence: reference_pricing_evidence_snapshot(component[:evidence], source_kind:).presence
      }.compact
    end

    def reference_pricing_evidence_snapshot(value, source_kind: nil)
      evidence = normalized_hash(value)
      return {} if evidence.blank?

      span_start = bounded_non_negative_integer(
        evidence[:provider_span_start],
        maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
      )
      span_end = bounded_non_negative_integer(
        evidence[:provider_span_end],
        maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
      )
      valid_span = span_start && span_end && span_end >= span_start

      line_group = source_kind == "azure_line_group"
      source_field_path = bounded_string(
        evidence[:source_field_path],
        max_bytes: REFERENCE_PRICING_SOURCE_FIELD_PATH_MAX_BYTES,
        pattern: line_group ?
          REFERENCE_PRICING_LINE_SOURCE_FIELD_PATH_PATTERN :
          REFERENCE_PRICING_SOURCE_FIELD_PATH_PATTERN
      )

      {
        source_provider: enum_string(
          evidence[:source_provider],
          line_group ? REFERENCE_PRICING_LINE_SOURCE_PROVIDERS : REFERENCE_PRICING_SOURCE_PROVIDERS
        ),
        source_field_path: source_field_path,
        item_index: line_group ? nil : bounded_non_negative_integer(
          evidence[:item_index],
          maximum: MAX_REFERENCE_PRICING_ITEM_INDEX
        ),
        string_index_type: line_group ? enum_string(
          evidence[:string_index_type],
          REFERENCE_PRICING_STRING_INDEX_TYPES
        ) : nil,
        provider_span_start: valid_span ? span_start : nil,
        provider_span_end: valid_span ? span_end : nil
      }.compact
    end

    def reference_pricing_summary_corroboration_snapshot(value)
      corroboration = normalized_hash(value)
      return {} if corroboration.blank?

      rounding_matches = Array(corroboration[:rounding_matches]).filter_map do |rounding_match|
        enum_string(rounding_match, REFERENCE_PRICING_ROUNDING_MATCHES)
      end.uniq.first(REFERENCE_PRICING_ROUNDING_MATCHES.size)

      {
        state: rounding_matches.any? ? "matched" : "mismatched",
        rounding_matches:
      }.compact
    end

    def reference_pricing_destination_snapshot(value, index_type:)
      destination = normalized_hash(value)
      return {} if destination.blank?

      page_index = bounded_non_negative_integer(
        destination[:page_index],
        maximum: MAX_REFERENCE_PRICING_PAGE_INDEX
      )
      name_line_index = bounded_non_negative_integer(
        destination[:name_line_index],
        maximum: MAX_REFERENCE_PRICING_LINE_INDEX
      )
      reference_line_index = bounded_non_negative_integer(
        destination[:reference_line_index],
        maximum: MAX_REFERENCE_PRICING_LINE_INDEX
      )
      purchased_line_index = bounded_non_negative_integer(
        destination[:purchased_quantity_line_index],
        maximum: MAX_REFERENCE_PRICING_LINE_INDEX
      )
      normalized_name_grapheme_length = bounded_non_negative_integer(
        destination[:normalized_name_grapheme_length],
        maximum: MAX_REFERENCE_PRICING_DESTINATION_GRAPHEMES
      )
      evidence = reference_pricing_destination_evidence_snapshot(
        destination[:evidence],
        index_type:
      )
      snapshot = {
        contract_version: enum_string(
          destination[:contract_version],
          REFERENCE_PRICING_DESTINATION_CONTRACTS
        ),
        kind: enum_string(destination[:kind], REFERENCE_PRICING_DESTINATION_KINDS),
        identity: bounded_string(
          destination[:identity],
          max_bytes: REFERENCE_PRICING_DESTINATION_ID_MAX_BYTES,
          pattern: /\Aazure_line_group_destination_p\d+_name_l\d+_s\d+_e\d+_ref_l\d+_qty_l\d+\z/
        ),
        page_index:,
        name_line_index:,
        reference_line_index:,
        purchased_quantity_line_index: purchased_line_index,
        normalized_name_grapheme_length:,
        evidence: evidence.presence
      }.compact
      return {} unless valid_reference_pricing_destination_snapshot?(snapshot, index_type:)

      snapshot
    end

    def reference_pricing_destination_evidence_snapshot(value, index_type:)
      evidence = normalized_hash(value)
      return {} if evidence.blank?

      span_start = bounded_non_negative_integer(
        evidence[:provider_span_start],
        maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
      )
      span_end = bounded_non_negative_integer(
        evidence[:provider_span_end],
        maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
      )
      valid_span = span_start && span_end && span_end > span_start

      {
        source_provider: enum_string(
          evidence[:source_provider],
          REFERENCE_PRICING_LINE_SOURCE_PROVIDERS
        ),
        source_field_path: bounded_string(
          evidence[:source_field_path],
          max_bytes: REFERENCE_PRICING_SOURCE_FIELD_PATH_MAX_BYTES,
          pattern: REFERENCE_PRICING_LINE_SOURCE_FIELD_PATH_PATTERN
        ),
        page_index: bounded_non_negative_integer(
          evidence[:page_index],
          maximum: MAX_REFERENCE_PRICING_PAGE_INDEX
        ),
        line_index: bounded_non_negative_integer(
          evidence[:line_index],
          maximum: MAX_REFERENCE_PRICING_LINE_INDEX
        ),
        string_index_type: enum_string(index_type, REFERENCE_PRICING_STRING_INDEX_TYPES),
        provider_span_start: valid_span ? span_start : nil,
        provider_span_end: valid_span ? span_end : nil,
        word_spans: reference_pricing_word_spans_snapshot(
          evidence[:word_spans],
          maximum: MAX_REFERENCE_PRICING_DESTINATION_WORDS
        ).presence,
        tax_word_spans: reference_pricing_word_spans_snapshot(
          evidence[:tax_word_spans],
          exact_count: REFERENCE_PRICING_TAX_WORD_COUNT
        ).presence
      }.compact
    end

    def reference_pricing_word_spans_snapshot(value, maximum: nil, exact_count: nil)
      spans = Array(value)
      return [] if maximum && !spans.size.between?(1, maximum)
      return [] if exact_count && spans.size != exact_count

      snapshots = spans.filter_map do |span|
        span = normalized_hash(span)
        start_offset = bounded_non_negative_integer(
          span[:provider_span_start],
          maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
        )
        end_offset = bounded_non_negative_integer(
          span[:provider_span_end],
          maximum: MAX_REFERENCE_PRICING_PROVIDER_SPAN_OFFSET
        )
        next unless start_offset && end_offset && end_offset > start_offset

        {
          source_field_path: bounded_string(
            span[:source_field_path],
            max_bytes: REFERENCE_PRICING_SOURCE_FIELD_PATH_MAX_BYTES,
            pattern: REFERENCE_PRICING_WORD_SOURCE_FIELD_PATH_PATTERN
          ),
          word_index: bounded_non_negative_integer(
            span[:word_index],
            maximum: MAX_REFERENCE_PRICING_WORD_INDEX
          ),
          provider_span_start: start_offset,
          provider_span_end: end_offset
        }.compact
      end
      return [] unless snapshots.size == spans.size

      snapshots
    end

    def valid_reference_pricing_destination_snapshot?(snapshot, index_type:)
      page_index = snapshot[:page_index]
      name_line_index = snapshot[:name_line_index]
      reference_line_index = snapshot[:reference_line_index]
      purchased_line_index = snapshot[:purchased_quantity_line_index]
      evidence = snapshot[:evidence]
      return false unless snapshot.keys.sort == %i[
        contract_version evidence identity kind name_line_index normalized_name_grapheme_length
        page_index purchased_quantity_line_index reference_line_index
      ].sort
      return false unless page_index == 0 && name_line_index == reference_line_index
      return false unless purchased_line_index == reference_line_index + 1
      return false unless snapshot[:normalized_name_grapheme_length].between?(3, MAX_REFERENCE_PRICING_DESTINATION_GRAPHEMES)
      return false unless snapshot[:identity] ==
        "azure_line_group_destination_p#{page_index}_name_l#{name_line_index}_" \
          "s#{evidence[:provider_span_start]}_e#{evidence[:provider_span_end]}_" \
          "ref_l#{reference_line_index}_qty_l#{purchased_line_index}"
      return false unless evidence[:source_provider] == "azure_line_group"
      return false unless evidence[:source_field_path] == "pages[#{page_index}].lines[#{name_line_index}]"
      return false unless evidence[:page_index] == page_index && evidence[:line_index] == name_line_index
      return false unless evidence[:string_index_type] == index_type.to_s
      return false unless exact_reference_pricing_word_coverage?(
        evidence[:word_spans],
        span_start: evidence[:provider_span_start],
        span_end: evidence[:provider_span_end]
      )

      ordered_reference_pricing_word_spans?(evidence[:tax_word_spans])
    rescue ArgumentError, KeyError, NoMethodError, TypeError
      false
    end

    def exact_reference_pricing_word_coverage?(spans, span_start:, span_end:)
      spans = Array(spans)
      spans.present? && spans.first[:provider_span_start] == span_start &&
        spans.last[:provider_span_end] == span_end &&
        spans.each_cons(2).all? do |left, right|
          left[:provider_span_end] == right[:provider_span_start]
        end && ordered_reference_pricing_word_spans?(spans)
    end

    def ordered_reference_pricing_word_spans?(spans)
      spans = Array(spans)
      spans.present? && spans.each_cons(2).all? do |left, right|
        left[:word_index] < right[:word_index] &&
          left[:provider_span_end] <= right[:provider_span_start]
      end
    end

    def valid_line_group_candidate_snapshot?(snapshot)
      page_index = snapshot[:page_index]
      reference_line_index = snapshot[:reference_line_index]
      purchased_line_index = snapshot[:purchased_quantity_line_index]
      index_type = snapshot[:string_index_type]
      return false unless page_index && reference_line_index && purchased_line_index && index_type
      return false unless page_index.zero?
      return false unless purchased_line_index == reference_line_index + 1
      return false unless snapshot[:candidate_id] ==
        "azure_line_group_p#{page_index}_l#{reference_line_index}_l#{purchased_line_index}_reference_pricing"
      return false unless snapshot[:validation_state] == "valid" && snapshot[:rejection_reasons] == []
      return false unless %w[gross net].include?(snapshot[:reference_price_tax_inclusion])
      return false unless valid_optional_line_group_destination?(snapshot, index_type:)

      expected_paths = {
        reference_price: "pages[#{page_index}].lines[#{reference_line_index}]",
        reference_quantity: "pages[#{page_index}].lines[#{reference_line_index}]",
        purchased_quantity: "pages[#{page_index}].lines[#{purchased_line_index}]"
      }
      expected_paths.all? do |component, expected_path|
        evidence = snapshot.dig(component, :evidence)
        valid_line_group_evidence?(evidence, expected_path:, index_type:)
      end && valid_line_group_evidence?(
        snapshot[:tax_inclusion_evidence],
        expected_path: expected_paths.fetch(:reference_price),
        index_type:
      )
    end

    def valid_optional_line_group_destination?(snapshot, index_type:)
      destination = snapshot[:destination_item_identity]
      return true if destination.nil?
      return false unless snapshot[:provider_model_id] == "prebuilt-receipt"
      return false unless snapshot[:provider_api_version] == "2024-11-30"
      return false unless snapshot[:validation_contract_version] == "azure_line_group_v1"
      return false unless snapshot[:analysis_profile_country_code] == "JPN"

      block_start = snapshot[:block_provider_span_start]
      block_end = snapshot[:block_provider_span_end]
      return false unless block_start.is_a?(Integer) && block_end.is_a?(Integer) && block_end > block_start
      return false unless destination[:reference_line_index] == snapshot[:reference_line_index]
      return false unless destination[:purchased_quantity_line_index] == snapshot[:purchased_quantity_line_index]

      tax_evidence = snapshot[:tax_inclusion_evidence]
      tax_words = destination.dig(:evidence, :tax_word_spans)
      tax_evidence.is_a?(Hash) && Array(tax_words).size == REFERENCE_PRICING_TAX_WORD_COUNT &&
        tax_words.first[:provider_span_start] == tax_evidence[:provider_span_start] &&
        tax_words.last[:provider_span_end] == tax_evidence[:provider_span_end] &&
        destination.dig(:evidence, :string_index_type) == index_type
    end

    def valid_line_group_evidence?(evidence, expected_path:, index_type:)
      evidence.is_a?(Hash) &&
        evidence[:source_provider] == "azure_line_group" &&
        evidence[:source_field_path] == expected_path &&
        evidence[:string_index_type] == index_type &&
        evidence[:provider_span_start].is_a?(Integer) &&
        evidence[:provider_span_end].is_a?(Integer) &&
        evidence[:provider_span_end] > evidence[:provider_span_start]
    end

    def reference_pricing_corroboration_snapshot(value)
      corroboration = normalized_hash(value)
      return {} if corroboration.blank?

      {
        exact_amount: reference_pricing_exact_fraction_snapshot(corroboration[:exact_amount]).presence,
        projected_amount: bounded_non_negative_integer(
          corroboration[:projected_amount],
          maximum: MAX_REFERENCE_PRICING_PROJECTED_AMOUNT
        ),
        printed_line_total: exact_decimal_string(corroboration[:printed_line_total]),
        rounding_matches: Array(corroboration[:rounding_matches]).filter_map do |rounding_match|
          enum_string(rounding_match, REFERENCE_PRICING_ROUNDING_MATCHES)
        end.uniq.first(REFERENCE_PRICING_ROUNDING_MATCHES.size)
      }.compact
    end

    def reference_pricing_exact_fraction_snapshot(value)
      fraction = normalized_hash(value)
      return {} if fraction.blank?

      denominator = exact_integer_string(fraction[:denominator])
      denominator = nil if denominator&.match?(/\A0+\z/)

      {
        numerator: exact_integer_string(fraction[:numerator]),
        denominator: denominator
      }.compact
    end

    def reference_pricing_rejection_reasons(value)
      Array(value).filter_map do |reason|
        enum_string(reason, REFERENCE_PRICING_REJECTION_REASONS)
      end.uniq.first(MAX_REFERENCE_PRICING_REJECTION_REASONS)
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
        quantity_unit_status = safe_quantity_unit_status(item[:quantity_unit_status])

        {
          raw_text: safe_string(item[:raw_text]),
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
          quantity_unit_code: safe_string(item[:quantity_unit_code]),
          quantity_unit_status: quantity_unit_status,
          quantity_unit_raw: safe_quantity_unit_raw(item[:quantity_unit_raw], status: quantity_unit_status),
          ocr_item_identity: bounded_string(
            item[:ocr_item_identity],
            max_bytes: ITEM_CALCULATION_MODE_ITEM_IDENTITY_MAX_BYTES,
            pattern: /\Aazure_structured_item_i\d+_s\d+_e\d+\z/
          ),
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

    def safe_quantity_unit_status(value)
      normalized = value.to_s
      safe_string(normalized) if QUANTITY_UNIT_STATUSES.include?(normalized)
    end

    def safe_quantity_unit_raw(value, status:)
      return nil unless status == "unknown"
      return nil unless safe_utf8_string?(value)

      truncate_string(value, max_bytes: QUANTITY_UNIT_RAW_MAX_BYTES).presence
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

        raw_category = safe_string(item[:category]).to_s.strip.presence
        category = raw_category if ReceiptItem::CATEGORIES.include?(raw_category)
        category_invalid = raw_category.present? && category.nil?
        review_reasons = Array(item[:review_reasons])
        review_reasons |= [ "item_category_uncertain" ] if category_invalid
        category_uncertain = review_reasons.include?("item_category_uncertain")

        {
          index: safe_value(item[:index]),
          position_index: safe_value(item[:position_index]),
          raw_text: safe_string(item[:raw_text]),
          suggested_name: safe_string(item[:suggested_name]),
          confirmed_name: safe_string(item[:confirmed_name]),
          category: category,
          price: safe_value(item[:price]),
          quantity: safe_value(item[:quantity]),
          quantity_unit_code: safe_string(item[:quantity_unit_code]),
          product_code: safe_string(item[:product_code]),
          tax_rate: safe_value(item[:tax_rate]),
          tax_rate_confidence: safe_value(item[:tax_rate_confidence]),
          tax_rate_reason: safe_string(item[:tax_rate_reason]),
          original_line_total: safe_value(item[:original_line_total]),
          line_total: safe_value(item[:line_total]),
          discount_amount: safe_value(item[:discount_amount]),
          discount_rate: safe_value(item[:discount_rate]),
          needs_review: category_uncertain ? true : (item.key?(:needs_review) ? item[:needs_review] == true : nil),
          review_reasons: limited_strings(review_reasons, snapshot_review_reasons_limit),
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
      ReceiptAiEnrichmentService.provider_metrics(value)
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

    def enum_string(value, allowed_values)
      return nil unless value.is_a?(String) || value.is_a?(Symbol)

      normalized = value.to_s
      normalized if allowed_values.include?(normalized)
    end

    def bounded_string(value, max_bytes:, pattern: nil)
      return nil unless safe_utf8_string?(value)
      return nil if value.empty? || value.bytesize > max_bytes
      return nil if pattern && !value.match?(pattern)

      value
    end

    def safe_utf8_string?(value)
      return false unless value.is_a?(String) && value.valid_encoding?
      return false unless value.encoding == Encoding::UTF_8 || value.ascii_only?

      !value.match?(SNAPSHOT_CONTROL_CHARACTER_PATTERN)
    rescue ArgumentError, Encoding::CompatibilityError
      false
    end

    def exact_decimal_string(value)
      bounded_string(
        value,
        max_bytes: REFERENCE_PRICING_EXACT_NUMBER_MAX_BYTES,
        pattern: /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/
      )
    end

    def exact_integer_string(value)
      bounded_string(
        value,
        max_bytes: REFERENCE_PRICING_EXACT_NUMBER_MAX_BYTES,
        pattern: /\A(?:0|[1-9]\d*)\z/
      )
    end

    def bounded_non_negative_integer(value, maximum:)
      value if value.is_a?(Integer) && value.between?(0, maximum)
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
