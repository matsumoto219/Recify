module Receipts::Processing::Runs
  class Tracker
    TERMINAL_STATUSES = %w[succeeded failed skipped superseded canceled].freeze
    STARTABLE_STAGES = %w[ocr ocr_validation ai finalize].freeze
    FINISHABLE_STAGES = %w[ocr ocr_validation ai finalize].freeze
    STAGE_EXECUTION_CLAIMS_METADATA_KEY = "stage_execution_claims".freeze
    SAFE_RECEIPT_FAILURE_MESSAGE_KEY = "receipts.processing_errors.unexpected_failure".freeze
    NEXT_STAGE = {
      "ocr" => "ocr_validation",
      "ocr_validation" => "ai",
      "ai" => "finalize",
      "finalize" => "completed"
    }.freeze

    def initialize(run)
      @run = run
    end

    def start_stage(stage, at: Time.current, provider: nil, model: nil)
      stage = normalize_stage!(stage, allowed: STARTABLE_STAGES)

      with_mutable_run do |locked_run|
        ensure_forward_transition!(locked_run, stage)

        attrs = {
          stage: stage,
          status: "running",
          started_at: locked_run.started_at || at
        }
        attrs.merge!(stage_start_attributes(stage, at: at, provider: provider, model: model))

        locked_run.update!(attrs)
        locked_run
      end
    end

    def claim_stage(stage, at: Time.current)
      stage = normalize_stage!(stage, allowed: STARTABLE_STAGES)

      run.with_lock do
        run.reload
        return false if TERMINAL_STATUSES.include?(run.status)
        return false if stage_index(stage) < stage_index(run.stage)

        metadata = run.metadata.to_h.deep_dup
        claims = metadata[STAGE_EXECUTION_CLAIMS_METADATA_KEY].to_h.deep_dup
        return false if claims.key?(stage)

        claims[stage] = { "claimed_at" => at.iso8601(6) }
        metadata[STAGE_EXECUTION_CLAIMS_METADATA_KEY] = claims
        run.update!(
          {
            stage: stage,
            status: "running",
            started_at: run.started_at || at,
            metadata: metadata
          }.merge(stage_start_attributes(stage, at: at, provider: nil, model: nil))
        )
        true
      end
    end

    def finish_stage(stage, at: Time.current)
      stage = normalize_stage!(stage, allowed: FINISHABLE_STAGES)

      with_mutable_run do |locked_run|
        unless locked_run.stage == stage
          raise Receipts::Processing::InvalidTransition, "Cannot finish stage=#{stage} from stage=#{locked_run.stage}"
        end

        attrs = stage_finish_attributes(locked_run, stage, at: at)
        attrs[:stage] = NEXT_STAGE.fetch(stage)

        locked_run.update!(attrs)
        locked_run
      end
    end

    def record_ocr_result(summary, latency_ms: nil, at: Time.current)
      summary = summary.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "ocr_validation"),
          status: "running",
          started_at: locked_run.started_at || at,
          ocr_finished_at: locked_run.ocr_finished_at || at,
          ocr_latency_ms: latency_ms || locked_run.ocr_latency_ms || latency_from(locked_run.ocr_started_at, at),
          ocr_provider: summary["provider"].presence || locked_run.ocr_provider,
          ocr_model: summary["model"].presence || locked_run.ocr_model,
          ocr_summary: summary
        )
        locked_run
      end
    end

    def record_ocr_snapshot(snapshot, at: Time.current)
      snapshot = snapshot.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "ocr_validation"),
          status: "running",
          started_at: locked_run.started_at || at,
          ocr_finished_at: locked_run.ocr_finished_at || at,
          ocr_result_snapshot: snapshot
        )
        locked_run
      end
    end

    def record_ai_input(snapshot, at: Time.current)
      snapshot = snapshot.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "ai"),
          status: "running",
          started_at: locked_run.started_at || at,
          ai_started_at: locked_run.ai_started_at || at,
          ai_input_snapshot: snapshot
        )
        locked_run
      end
    end

    def record_ai_result(summary, latency_ms: nil, at: Time.current)
      summary = summary.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "finalize"),
          status: "running",
          ai_finished_at: locked_run.ai_finished_at || at,
          ai_latency_ms: latency_ms || locked_run.ai_latency_ms || latency_from(locked_run.ai_started_at, at),
          ai_provider: summary["provider"].presence || locked_run.ai_provider,
          ai_model: summary["model"].presence || locked_run.ai_model,
          ai_fallback_provider: summary["fallback_provider"].presence || locked_run.ai_fallback_provider,
          ai_fallback_used: summary["fallback_used"] == true,
          ai_result_summary: summary
        )
        locked_run
      end
    end

    def record_ai_normalized_result(snapshot, at: Time.current)
      snapshot = snapshot.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "finalize"),
          status: "running",
          ai_finished_at: locked_run.ai_finished_at || at,
          ai_normalized_result_snapshot: snapshot
        )
        locked_run
      end
    end

    def record_finalize_decision(snapshot, at: Time.current)
      snapshot = snapshot.to_h

      with_mutable_run do |locked_run|
        metadata = locked_run.metadata.to_h.deep_dup
        metadata["finalize_decision"] = snapshot

        locked_run.update!(
          stage: advanced_stage(locked_run, "finalize"),
          status: "running",
          started_at: locked_run.started_at || at,
          metadata: metadata
        )
        locked_run
      end
    end

    def record_build_params_snapshot(snapshot, at: Time.current)
      snapshot = snapshot.to_h

      with_mutable_run do |locked_run|
        metadata = locked_run.metadata.to_h.deep_dup
        metadata["build_params_snapshot"] = snapshot

        locked_run.update!(
          stage: advanced_stage(locked_run, "finalize"),
          status: "running",
          started_at: locked_run.started_at || at,
          metadata: metadata
        )
        locked_run
      end
    end

    def record_final_result(summary, at: Time.current)
      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "completed"),
          status: "running",
          finalized_at: locked_run.finalized_at || at,
          final_result_summary: summary.to_h
        )
        locked_run
      end
    end

    def copy_retry_snapshots(ocr_summary: nil, ocr_result_snapshot: nil, ai_result_summary: nil, ai_normalized_result_snapshot: nil, finalize_decision_snapshot: nil)
      with_mutable_run do |locked_run|
        attrs = {}
        attrs[:ocr_summary] = ocr_summary.to_h if ocr_summary
        attrs[:ocr_result_snapshot] = ocr_result_snapshot.to_h if ocr_result_snapshot
        attrs[:ai_result_summary] = ai_result_summary.to_h if ai_result_summary
        attrs[:ai_normalized_result_snapshot] = ai_normalized_result_snapshot.to_h if ai_normalized_result_snapshot

        if finalize_decision_snapshot
          metadata = locked_run.metadata.to_h.deep_dup
          metadata["finalize_decision"] = finalize_decision_snapshot.to_h
          attrs[:metadata] = metadata
        end

        locked_run.update!(attrs) if attrs.present?
        locked_run
      end
    end

    def succeed(at: Time.current)
      terminate!("succeeded", at: at)
    end

    def fail(error_stage:, error_code:, error_message: nil, error_metadata: nil, at: Time.current)
      ReceiptAnalysisRun.transaction do
        failed_run = terminate!(
          "failed",
          at: at,
          error_stage: error_stage,
          error_code: error_code,
          error_message: error_message,
          error_metadata: error_metadata
        )
        sync_processing_receipt_failure!(failed_run)
        failed_run
      end
    end

    def supersede(at: Time.current)
      terminate!("superseded", at: at)
    end

    def cancel(at: Time.current)
      terminate!("canceled", at: at)
    end

    def mark_stale!(at: Time.current, error_code: "analysis_stale_run")
      run.with_lock do
        run.reload
        ensure_not_terminal!(run)

        receipt = run.receipt
        receipt_processing = stale_receipt_processing?(receipt)
        status = receipt_processing ? "failed" : "canceled"

        run.update!(
          status: status,
          stage: terminal_stage_for(status, run),
          finished_at: at,
          finalized_at: run.finalized_at,
          total_latency_ms: run.total_latency_ms || latency_from(run.started_at, at),
          error_stage: terminal_error_value(status, run.stage),
          error_code: terminal_error_value(status, error_code),
          error_message: terminal_error_value(status, safe_error_message(error_code)),
          expires_at: ReceiptAnalysisRun.default_expires_at_for(
            status: status,
            source: run.source,
            receipt_status: receipt_processing ? "failed" : final_receipt_status(run),
            from: at
          )
        )
        run
      end
    end

    private

    attr_reader :run

    def with_mutable_run
      run.with_lock do
        run.reload
        ensure_not_terminal!(run)
        yield run
      end
    end

    def terminate!(status, at:, error_stage: nil, error_code: nil, error_message: nil, error_metadata: nil)
      run.with_lock do
        run.reload
        ensure_not_terminal!(run)

        attrs = {
          status: status,
          stage: terminal_stage_for(status, run),
          finished_at: at,
          finalized_at: run.finalized_at || (status == "succeeded" ? at : nil),
          total_latency_ms: run.total_latency_ms || latency_from(run.started_at, at),
          error_stage: terminal_error_value(status, error_stage || run.error_stage),
          error_code: terminal_error_value(status, error_code || run.error_code),
          error_message: terminal_error_value(status, safe_error_message(error_message || run.error_message)),
          expires_at: ReceiptAnalysisRun.default_expires_at_for(
            status: status,
            source: run.source,
            receipt_status: final_receipt_status(run),
            from: at
          )
        }
        metadata = safe_error_metadata(error_metadata)
        if metadata.present?
          attrs[:metadata] = run.metadata.to_h.deep_dup.merge("error_metadata" => metadata)
        end

        run.update!(attrs)
        run
      end
    end

    def normalize_stage!(stage, allowed:)
      normalized = stage.to_s
      raise Receipts::Processing::InvalidTransition, "Unknown stage=#{stage}" unless allowed.include?(normalized)

      normalized
    end

    def ensure_not_terminal!(locked_run)
      return unless TERMINAL_STATUSES.include?(locked_run.status)

      raise Receipts::Processing::TerminalRunError, "ReceiptAnalysisRun id=#{locked_run.id} is already terminal status=#{locked_run.status}"
    end

    def ensure_forward_transition!(locked_run, target_stage)
      current_index = stage_index(locked_run.stage)
      target_index = stage_index(target_stage)
      return if target_index >= current_index

      raise Receipts::Processing::InvalidTransition, "Cannot move stage from #{locked_run.stage} to #{target_stage}"
    end

    def advanced_stage(locked_run, target_stage)
      stage_index(target_stage) > stage_index(locked_run.stage) ? target_stage : locked_run.stage
    end

    def stage_index(stage)
      ReceiptAnalysisRun::STAGES.index(stage.to_s) || -1
    end

    def stage_start_attributes(stage, at:, provider:, model:)
      case stage
      when "ocr"
        {
          ocr_started_at: at,
          ocr_provider: provider,
          ocr_model: model
        }.compact
      when "ai"
        {
          ai_started_at: at,
          ai_provider: provider,
          ai_model: model
        }.compact
      else
        {}
      end
    end

    def stage_finish_attributes(locked_run, stage, at:)
      case stage
      when "ocr"
        {
          ocr_finished_at: at,
          ocr_latency_ms: locked_run.ocr_latency_ms || latency_from(locked_run.ocr_started_at, at)
        }
      when "ai"
        {
          ai_finished_at: at,
          ai_latency_ms: locked_run.ai_latency_ms || latency_from(locked_run.ai_started_at, at)
        }
      when "finalize"
        {
          finalized_at: at
        }
      else
        {}
      end
    end

    def terminal_stage_for(status, locked_run)
      return "completed" if status == "succeeded"
      return "completed" if locked_run.stage == "completed"
      return "completed" if locked_run.status == "running" && locked_run.finalized_at.present?

      locked_run.stage
    end

    def terminal_error_value(status, value)
      status == "failed" ? value : nil
    end

    def stale_receipt_processing?(receipt)
      receipt.with_lock do
        receipt.reload
        if receipt.processing?
          receipt.update!(
            status: "failed",
            processing_error_code: "analysis_stale_run",
            processing_error_message: safe_receipt_failure_message,
            review_reasons: []
          )
          true
        else
          false
        end
      end
    end

    def sync_processing_receipt_failure!(failed_run)
      receipt = failed_run.receipt
      receipt.with_lock do
        receipt.reload
        return unless receipt.processing?

        receipt.update!(
          status: "failed",
          processing_error_code: safe_receipt_error_code(failed_run.error_code),
          processing_error_message: safe_receipt_failure_message,
          review_reasons: []
        )
      end
    end

    def safe_receipt_error_code(error_code)
      error_code.presence || "unexpected_error"
    end

    def safe_receipt_failure_message
      I18n.t(SAFE_RECEIPT_FAILURE_MESSAGE_KEY)
    end

    def final_receipt_status(locked_run)
      return unless locked_run.final_result_summary.respond_to?(:[])

      locked_run.final_result_summary["receipt_status"] || locked_run.final_result_summary[:receipt_status]
    end

    def latency_from(started_at, finished_at)
      return nil if started_at.blank? || finished_at.blank?

      ((finished_at - started_at) * 1000).round
    end

    def safe_error_message(value)
      return nil if value.blank?

      text = SecurityEvents.sanitize_exception_message(value)
      return text if text.bytesize <= SnapshotBuilder::STRING_MAX_BYTES

      truncated = +""
      text.each_char do |char|
        break if truncated.bytesize + char.bytesize > SnapshotBuilder::STRING_MAX_BYTES

        truncated << char
      end
      truncated
    end

    def safe_error_metadata(value)
      return {} unless value.respond_to?(:to_h)

      metadata = value.to_h.with_indifferent_access
      {
        "error" => safe_error_metadata_text(metadata[:error]),
        "resource" => safe_error_metadata_text(metadata[:resource]),
        "field" => safe_error_metadata_text(metadata[:field]),
        "limit" => safe_error_metadata_integer(metadata[:limit]),
        "actual_value" => safe_error_metadata_integer(metadata[:actual_value]),
        "actual_count" => safe_error_metadata_integer(metadata[:actual_count]),
        "snapshot_count" => safe_error_metadata_integer(metadata[:snapshot_count]),
        "index" => safe_error_metadata_integer(metadata[:index]),
        "provider_detail" => safe_provider_error_detail(metadata[:provider_detail] || metadata[:provider_error_detail])
      }.compact
    end

    def safe_provider_error_detail(value)
      detail = value.to_h.with_indifferent_access if value.respond_to?(:to_h)
      return nil if detail.blank?

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
      ).presence
    end

    def safe_error_metadata_text(value)
      text = value.to_s.strip
      return nil if text.blank?

      text.truncate(100)
    end

    def safe_error_metadata_integer(value)
      Integer(value, exception: false)
    end
  end
end
