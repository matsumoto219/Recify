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
      raw_response
      response_body
      signed_id
      token
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
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @receipt = receipt
      @receipt_id = receipt_id
      @receipt_public_id = receipt_public_id
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

      {
        run: run,
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
        summaries: {
          ocr: safe_summary(run.ocr_summary),
          ai_input: safe_summary(run.ai_input_snapshot),
          ai_result: safe_summary(run.ai_result_summary),
          final_result: safe_summary(run.final_result_summary)
        },
        retry_options: Analysis::RetryService.eligibility(receipt: receipt, parent_run: run).retry_options
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
