module Admin
  class ReceiptAnalysisRunsQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    ATTENTION_RECEIPT_STATUSES = %w[review_needed failed].freeze
    FORBIDDEN_SUMMARY_KEYS = %w[
      azure_raw_response
      blob_key
      image
      openai_raw_response
      prompt
      prompt_text
      api_key
      ai_raw_response
      full_prompt
      image_payload
      raw_response
      raw_ai_response
      provider_raw_response
      response_body
      signed_id
      system_prompt
      token
      user_prompt
    ].freeze
    FORBIDDEN_SUMMARY_KEY_FRAGMENTS = %w[
      authorization
      password
      secret
      signed_id
    ].freeze

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end
    end

    def initialize(
      receipt: nil,
      receipt_id: nil,
      receipt_public_id: nil,
      run_key: nil,
      user: nil,
      user_id: nil,
      status: nil,
      stage: nil,
      error_code: nil,
      source: nil,
      receipt_status: nil,
      needs_attention: false,
      expires_before: nil,
      expires_within: nil,
      include_retry_options: false,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @receipt = receipt
      @receipt_id = receipt_id
      @receipt_public_id = receipt_public_id
      @run_key = run_key
      @user = user
      @user_id = user_id
      @status = status
      @stage = stage
      @error_code = error_code
      @source = source
      @receipt_status = receipt_status
      @needs_attention = needs_attention
      @expires_before = expires_before
      @expires_within = expires_within
      @include_retry_options = ActiveModel::Type::Boolean.new.cast(include_retry_options)
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      runs = relation.order(created_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a

      Result.new(
        records: runs.map { |run| build_record(run) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = ReceiptAnalysisRun.includes(:requested_by_user, receipt: :user)
      relation = filter_by_run_key(relation)
      relation = filter_by_receipt(relation)
      relation = filter_by_user(relation)
      relation = filter_by_column(relation, :status, @status)
      relation = filter_by_column(relation, :stage, @stage)
      relation = filter_by_column(relation, :source, @source)
      relation = filter_by_error_code(relation)
      relation = filter_by_receipt_status(relation)
      relation = filter_by_attention(relation)
      filter_by_expiration(relation)
    end

    def filter_by_run_key(relation)
      values = filter_values(@run_key)
      return relation if values.blank?

      relation.where(run_key: values)
    end

    def filter_by_receipt(relation)
      if @receipt.present?
        relation.where(receipt_id: @receipt.id)
      elsif @receipt_id.present?
        relation.where(receipt_id: @receipt_id)
      elsif @receipt_public_id.present?
        relation.joins(:receipt).where(receipts: { public_id: @receipt_public_id })
      else
        relation
      end
    end

    def filter_by_user(relation)
      target_user_id = @user&.id || @user_id
      return relation if target_user_id.blank?

      relation.joins(:receipt).where(receipts: { user_id: target_user_id })
    end

    def filter_by_column(relation, column, value)
      values = filter_values(value)
      return relation if values.blank?

      relation.where(column => values)
    end

    def filter_by_error_code(relation)
      values = filter_values(@error_code)
      return relation if values.blank?

      relation.where(error_code: values).or(
        relation.where("receipt_analysis_runs.final_result_summary ->> 'processing_error_code' IN (?)", values)
      )
    end

    def filter_by_receipt_status(relation)
      values = filter_values(@receipt_status)
      return relation if values.blank?

      relation.where("receipt_analysis_runs.final_result_summary ->> 'receipt_status' IN (?)", values)
    end

    def filter_by_attention(relation)
      return relation unless ActiveModel::Type::Boolean.new.cast(@needs_attention)

      relation.where(status: "failed").or(
        relation.where(
          "receipt_analysis_runs.final_result_summary ->> 'receipt_status' IN (?)",
          ATTENTION_RECEIPT_STATUSES
        )
      )
    end

    def filter_by_expiration(relation)
      expires_before = expiration_cutoff
      return relation if expires_before.blank?

      relation.where(expires_at: ..expires_before)
    end

    def expiration_cutoff
      return @expires_before if @expires_before.present?
      return if @expires_within.blank?

      Time.current + @expires_within
    end

    def build_record(run)
      receipt = run.receipt
      user = receipt.user
      receipt_status = receipt_status_for(run)
      processing_error_code = processing_error_code_for(run)
      summaries = {
        ocr: safe_summary(run.ocr_summary),
        ai_input: safe_summary(run.ai_input_snapshot),
        ai_result: safe_summary(run.ai_result_summary),
        final_result: safe_summary(run.final_result_summary)
      }
      detailed_snapshots = {
        ocr_result_snapshot: safe_summary(run.ocr_result_snapshot),
        ai_normalized_result_snapshot: safe_summary(run.ai_normalized_result_snapshot),
        build_params_snapshot: safe_summary(run.metadata.to_h["build_params_snapshot"] || {})
      }
      amount_calculation_profile = safe_summary(receipt.amount_calculation_profile || {})

      record = {
        run: run,
        run_key: run.run_key,
        receipt: receipt,
        user: user,
        public_id: receipt.public_id,
        display_id: receipt.display_id,
        stage: run.stage,
        status: run.status,
        source: run.source,
        receipt_status: receipt_status,
        error_code: run.error_code.presence || processing_error_code,
        pipeline_error_code: run.error_code,
        processing_error_code: processing_error_code,
        error_stage: run.error_stage,
        receipt_info: receipt_info(receipt),
        user_info: user_info(user),
        latency_ms: {
          ocr: run.ocr_latency_ms,
          ai: run.ai_latency_ms,
          total: run.total_latency_ms
        },
        provider: {
          ocr: compact_provider(provider: run.ocr_provider, model: run.ocr_model),
          ai: compact_provider(provider: run.ai_provider, model: run.ai_model),
          ai_fallback: compact_provider(provider: run.ai_fallback_provider, used: run.ai_fallback_used)
        },
        timestamps: {
          created_at: run.created_at,
          started_at: run.started_at,
          finished_at: run.finished_at,
          expires_at: run.expires_at
        },
        summaries: summaries,
        detailed_snapshots: detailed_snapshots,
        correction_summary: correction_summary(
          detailed_snapshots: detailed_snapshots,
          amount_calculation_profile: amount_calculation_profile
        ),
        ai_input_highlights: ai_input_highlights(
          ai_input_snapshot: summaries[:ai_input],
          ocr_result_snapshot: detailed_snapshots[:ocr_result_snapshot]
        ),
        snapshot_presence: snapshot_presence(run),
        finalize_decision: safe_summary(run.metadata.to_h["finalize_decision"] || {}),
        amount_calculation_profile: amount_calculation_profile
      }
      record[:retry_options] = Analysis::RetryService.eligibility(receipt: receipt, parent_run: run).retry_options if include_retry_options?
      record
    end

    def receipt_info(receipt)
      {
        public_id: receipt.public_id,
        display_id: receipt.display_id,
        status: receipt.status,
        store_name: receipt.store_name,
        total_amount: receipt.total_amount,
        purchased_at: receipt.purchased_at,
        review_reasons: receipt.review_reasons,
        updated_at: receipt.updated_at
      }
    end

    def user_info(user)
      {
        id: user.id,
        guest: user.guest?,
        admin: user.admin?
      }
    end

    def snapshot_presence(run)
      {
        ocr_summary: run.ocr_summary.present?,
        ocr_result_snapshot: run.ocr_result_snapshot.present?,
        ai_input_snapshot: run.ai_input_snapshot.present?,
        ai_result_summary: run.ai_result_summary.present?,
        ai_normalized_result_snapshot: run.ai_normalized_result_snapshot.present?,
        build_params_snapshot: run.metadata.to_h["build_params_snapshot"].present?,
        final_result_summary: run.final_result_summary.present?,
        finalize_decision: run.metadata.to_h["finalize_decision"].present?
      }
    end

    def receipt_status_for(run)
      summary = run.final_result_summary
      summary["receipt_status"].presence || run.receipt.status
    end

    def processing_error_code_for(run)
      run.final_result_summary["processing_error_code"].presence || run.receipt.processing_error_code
    end

    def compact_provider(**values)
      values.compact
    end

    def correction_summary(detailed_snapshots:, amount_calculation_profile:)
      build_params_snapshot = indifferent_hash(detailed_snapshots[:build_params_snapshot])
      ai_normalized_snapshot = indifferent_hash(detailed_snapshots[:ai_normalized_result_snapshot])
      amount_profile = indifferent_hash(amount_calculation_profile)
      fallback = indifferent_hash(build_params_snapshot.dig(:corrections, :purchased_at_fallback))
      tax_rate_correction = build_params_snapshot.dig(:corrections, :tax_rate_correction) ||
        amount_profile.dig(:profile, :tax_rate_correction)

      {
        purchased_at_fallback: {
          applied: fallback[:applied] == true,
          source: fallback[:source],
          result: fallback[:result]
        }.compact,
        tax_rate_corrections_count: tax_rate_corrections_count(tax_rate_correction),
        adjustment_count: integer_or_zero(build_params_snapshot[:receipt_adjustments_count]),
        uncertain_adjustments_count: uncertain_adjustments_count(ai_normalized_snapshot),
        amount_warnings_count: amount_warnings_count(amount_profile),
        amount_blocking_count: amount_blocking_count(amount_profile),
        tax_detail_amount_basis: tax_detail_amount_basis(amount_profile)
      }
    end

    def tax_rate_corrections_count(correction)
      correction = indifferent_hash(correction)
      matches = Array(correction[:matches])
      return matches.size if matches.present?

      integer_or_zero(correction[:item_count]) + integer_or_zero(correction[:adjustment_count])
    end

    def uncertain_adjustments_count(ai_normalized_snapshot)
      Array(ai_normalized_snapshot[:receipt_adjustments_attributes]).count do |adjustment|
        adjustment = indifferent_hash(adjustment)
        adjustment[:needs_review] == true || Array(adjustment[:review_reasons]).present?
      end
    end

    def amount_warnings_count(amount_profile)
      [
        Array(amount_profile[:warnings]).size,
        Array(amount_profile[:warning_mismatch_codes]).size
      ].max
    end

    def amount_blocking_count(amount_profile)
      Array(amount_profile[:blocking_mismatch_codes]).size
    end

    def tax_detail_amount_basis(amount_profile)
      amount_profile.dig(:profile, :tax_detail_amount_basis).presence ||
        amount_profile.dig(:computed, :tax_detail_amount_basis).presence ||
        amount_profile.dig(:resolved, :tax_detail_amount_basis).presence
    end

    def ai_input_highlights(ai_input_snapshot:, ocr_result_snapshot:)
      ai_input = indifferent_hash(ai_input_snapshot)
      ocr_snapshot = indifferent_hash(ocr_result_snapshot)

      {
        purchase: compact_highlight(indifferent_hash(ai_input[:purchase]).slice(
          :purchased_at_text,
          :purchased_at_candidates,
          :purchase_context_lines
        )),
        tax: compact_highlight(indifferent_hash(ai_input[:tax]).slice(
          :tax_details,
          :tax_context_lines
        )),
        items: ai_input_item_highlights(ai_input[:items]),
        adjustments: compact_highlight(
          adjustment_candidates: ai_input[:adjustment_candidates] ||
            ocr_snapshot.dig(:candidates, :adjustment_candidates),
          adjustment_context_lines: ai_input[:adjustment_context_lines]
        ),
        context: compact_highlight(
          full_context_lines: ai_input[:full_context_lines],
          filtered_content: ai_input[:filtered_content]
        )
      }.compact
    end

    def ai_input_item_highlights(items)
      highlights = Array(items).filter_map do |item|
        item = indifferent_hash(item)
        compact_highlight(item.slice(
          :index,
          :raw_text,
          :line_total,
          :tax_rate,
          :tax_rate_candidate,
          :matched_content_lines,
          :matched_filtered_content_lines
        ))
      end

      highlights.presence
    end

    def compact_highlight(value)
      value.compact_blank.presence
    end

    def integer_or_zero(value)
      return value if value.is_a?(Integer)

      value.to_i
    end

    def indifferent_hash(value)
      value.respond_to?(:with_indifferent_access) ? value.with_indifferent_access : {}.with_indifferent_access
    end

    def filter_values(value)
      Array(value).filter_map do |item|
        normalized = item.to_s
        normalized.presence
      end
    end

    def normalize_limit(value)
      normalized = value.to_i
      normalized = DEFAULT_LIMIT if normalized <= 0

      [ normalized, MAX_LIMIT ].min
    end

    def normalize_offset(value)
      [ value.to_i, 0 ].max
    end

    def include_retry_options?
      @include_retry_options
    end

    def safe_summary(value)
      sanitize_summary(value)
    end

    def sanitize_summary(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child_value), memo|
          normalized_key = key.to_s
          next if forbidden_summary_key?(normalized_key)

          memo[normalized_key] = sanitize_summary(child_value)
        end
      when Array
        value.map { |child_value| sanitize_summary(child_value) }
      else
        value
      end
    end

    def forbidden_summary_key?(key)
      normalized_key = key.to_s.downcase

      FORBIDDEN_SUMMARY_KEYS.include?(normalized_key) ||
        FORBIDDEN_SUMMARY_KEY_FRAGMENTS.any? { |fragment| normalized_key.include?(fragment) }
    end
  end
end
