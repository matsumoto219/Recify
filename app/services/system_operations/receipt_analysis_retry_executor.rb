module SystemOperations
  class ReceiptAnalysisRetryExecutor
    SOURCE = "admin_retry".freeze
    CONFIRMATION_TEXT = "RETRY ANALYSIS".freeze
    RETRY_TYPES = %w[
      full_reanalyze
      ocr_retry
      ai_retry
      finalize_retry
    ].freeze
    ACTIVE_RUN_UNSET = Object.new.freeze

    Result = Struct.new(:run, :enqueued_job, :retry_type, :error_code, :error_message, keyword_init: true) do
      def success?
        error_code.blank?
      end

      def failure?
        !success?
      end
    end
    Eligibility = Struct.new(:retry_options, keyword_init: true)

    class << self
      def call(receipt:, parent_run: nil, actor:, retry_type:, reason: nil, request: nil, reauthentication: nil, confirmation: nil)
        new(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: retry_type,
          reason: reason,
          request: request,
          reauthentication: reauthentication,
          confirmation: confirmation
        ).call
      end

      def eligibility(receipt:, parent_run:)
        active_run = receipt&.receipt_analysis_runs&.active&.order(created_at: :desc)&.first

        Eligibility.new(
          retry_options: RETRY_TYPES.map do |type|
            new(
              receipt: receipt,
              parent_run: parent_run,
              actor: nil,
              retry_type: type,
              reason: nil,
              request: nil,
              reauthentication: nil,
              confirmation: nil,
              active_run: active_run
            ).retry_option
          end
        )
      end
    end

    def initialize(receipt:, parent_run:, actor:, retry_type:, reason:, request:, reauthentication:, confirmation:, active_run: ACTIVE_RUN_UNSET)
      @receipt = receipt
      @parent_run = parent_run
      @actor = actor
      @retry_type = retry_type.to_s
      @reason = reason.to_s.strip
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
      @confirmation = confirmation.to_s.strip
      @active_run = active_run unless active_run.equal?(ACTIVE_RUN_UNSET)
    end

    def call
      @audit_before_state = build_audit_before_state

      unless RETRY_TYPES.include?(retry_type)
        result = failure(:invalid_retry_type, "Unknown retry_type=#{retry_type}")
        record_audit!(result)
        return result
      end

      unless actor
        result = failure(:actor_required, "actor is required")
        record_audit!(result)
        return result
      end

      if reason.blank?
        result = failure(:reason_required, "reason is required")
        record_audit!(result)
        return result
      end

      unless fresh_passkey_reauthentication?
        result = failure(:reauthentication_required, "passkey reauthentication is required")
        record_audit!(result)
        return result
      end

      unless confirmation_valid?
        result = failure(:confirmation_required, "confirmation is required")
        record_audit!(result)
        return result
      end

      if (disabled_reason = disabled_reason_for(retry_type))
        result = failure(disabled_reason, disabled_message(disabled_reason), run: disabled_run_for(disabled_reason))
        record_audit!(result)
        return result
      end

      result = nil

      begin
        ReceiptAnalysisRun.transaction do
          start_result = ReceiptAnalysisRuns.start(
            receipt: receipt,
            source: SOURCE,
            requested_by_user: actor,
            request_reason: reason,
            parent_run: parent_run
          )

          unless start_result.created?
            result = failure(:active_run_exists, "receipt already has an active analysis run", run: start_result.run)
            raise ActiveRecord::Rollback
          end

          run = start_result.run
          unless consume_retry_operation_limit
            result = failure(:usage_limit_exceeded, "usage_limit_exceeded")
            raise ActiveRecord::Rollback
          end

          copy_retry_snapshots(run)
          mark_receipt_processing!

          result = Result.new(run: run, enqueued_job: job_class, retry_type: retry_type)
          record_retry_requested_audit!(result)
        end
      rescue ExternalServices::RuntimeConfigUnavailableError
        result = failure(:runtime_config_unavailable, "runtime config is unavailable")
        record_audit!(result)
        return result
      end

      if result&.failure?
        record_audit!(result)
        return result
      end

      return result if result.failure?

      begin
        ReceiptAnalysisRuns.enqueue(result.run, job_class: result.enqueued_job)
      rescue ReceiptAnalysisRuns::EnqueueError
        result = failure(
          :analysis_enqueue_failed,
          "analysis job enqueue failed",
          run: result.run
        )
        record_audit!(result)
        return result
      end

      record_audit!(result)
      result
    end

    def retry_option
      disabled_reason = disabled_reason_for(retry_type)

      {
        type: retry_type,
        possible: disabled_reason.blank?,
        disabled_reason: disabled_reason
      }
    end

    private

    attr_reader :receipt, :parent_run, :actor, :retry_type, :reason, :request, :reauthentication, :confirmation

    def fresh_passkey_reauthentication?
      Admin.passkey_reauth_fresh?(reauthentication)
    end

    def reauthenticated_at
      Admin.passkey_reauthenticated_at(reauthentication)
    end

    def confirmation_valid?
      confirmation == CONFIRMATION_TEXT
    end

    def parent_finalize_decision
      @parent_finalize_decision ||= ReceiptAnalysisPipeline.finalize_decision_from_snapshot(
        parent_run&.metadata.to_h["finalize_decision"]
      )
    end

    def disabled_reason_for(type)
      if parent_run.present? && parent_run.receipt_id != receipt&.id
        return "parent_run_receipt_mismatch"
      end
      return "active_run_exists" if active_run_exists?

      case type
      when "full_reanalyze", "ocr_retry"
        return "image_missing" unless receipt&.image&.attached?
        return "ocr_unavailable" if ExternalServices.down?(:ocr)
      when "ai_retry"
        return "parent_run_missing" if parent_run.blank?
        return "ocr_snapshot_missing" if parent_run.ocr_result_snapshot.blank?
        return "ai_unavailable" if ExternalServices.down?(:ai)
      when "finalize_retry"
        return "parent_run_missing" if parent_run.blank?
        return "finalize_decision_missing" if parent_finalize_decision.blank?
        requirements = finalize_retry_snapshot_requirements
        return "ocr_snapshot_missing" if requirements[:ocr] && parent_run.ocr_result_snapshot.blank?
        return "ai_snapshot_missing" if requirements[:ai] && parent_run.ai_normalized_result_snapshot.blank?
      end

      nil
    end

    def active_run_exists?
      active_run.present?
    end

    def active_run
      return @active_run if instance_variable_defined?(:@active_run)
      return unless receipt

      @active_run = receipt.receipt_analysis_runs.active.order(created_at: :desc).first
    end

    def disabled_run_for(disabled_reason)
      active_run if disabled_reason.to_s == "active_run_exists"
    end

    def disabled_message(disabled_reason)
      case disabled_reason.to_s
      when "active_run_exists"
        "receipt already has an active analysis run"
      when "image_missing"
        "receipt image is required"
      when "ocr_unavailable"
        "OCR service is unavailable"
      when "ai_unavailable"
        "AI service is unavailable"
      when "parent_run_missing"
        "parent_run is required"
      when "parent_run_receipt_mismatch"
        "parent_run must belong to the receipt"
      when "ocr_snapshot_missing"
        "parent_run.ocr_result_snapshot is required"
      when "ai_snapshot_missing"
        "parent_run.ai_normalized_result_snapshot is required"
      when "finalize_decision_missing"
        "parent_run.metadata.finalize_decision is required"
      else
        "retry is not available"
      end
    end

    def copy_retry_snapshots(run)
      case retry_type
      when "ai_retry"
        ReceiptAnalysisRuns.copy_retry_snapshots(run, parent_run: parent_run, include_ocr: true)
      when "finalize_retry"
        requirements = finalize_retry_snapshot_requirements
        ReceiptAnalysisRuns.copy_retry_snapshots(
          run,
          parent_run: parent_run,
          include_ocr: requirements[:ocr],
          include_ai: requirements[:ai],
          include_finalize_decision: true
        )
      end
    end

    def finalize_retry_snapshot_requirements
      case parent_finalize_decision&.finalize_strategy.to_s
      when "ai_success"
        { ocr: true, ai: true }
      when "ai_fallback", "ocr_only"
        { ocr: true, ai: false }
      when "fail_receipt"
        { ocr: false, ai: false }
      else
        { ocr: false, ai: false }
      end
    end

    def mark_receipt_processing!
      receipt.update!(
        status: "processing",
        processing_error_code: nil,
        processing_error_message: nil,
        review_reasons: []
      )
    end

    def consume_retry_operation_limit
      Usage.consume_retry_operation!(user: actor)
      true
    rescue Usage::LimitExceeded
      false
    end

    def job_class
      case retry_type
      when "full_reanalyze", "ocr_retry"
        ReceiptOcrJob
      when "ai_retry"
        ReceiptAiEnrichmentJob
      when "finalize_retry"
        ReceiptFinalizeJob
      end
    end

    def record_audit!(result)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: audit_action,
        target: receipt,
        target_uid: receipt&.public_id,
        reason: reason,
        outcome: result.success? ? "succeeded" : "failed",
        error_code: result.error_code,
        metadata: audit_metadata(result),
        before_state: audit_before_state,
        after_state: audit_after_state(result),
        request: request
      )
    end

    def record_retry_requested_audit!(result)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: "receipt_analysis.retry_requested",
        target: receipt,
        target_uid: receipt&.public_id,
        reason: reason,
        outcome: "succeeded",
        metadata: {
          retry_type: audit_retry_type,
          intended_action: audit_action,
          parent_run_key: parent_run&.run_key,
          new_run_key: result.run&.run_key,
          job_class: result.enqueued_job&.name,
          source: SOURCE
        }.merge(reauthentication_metadata),
        before_state: audit_before_state,
        after_state: {
          receipt_status: receipt&.status,
          new_run_key: result.run&.run_key,
          new_run_status: result.run&.status,
          enqueue_status: "pending"
        },
        request: request
      )
    end

    def audit_action
      case retry_type
      when "full_reanalyze"
        "receipt_analysis.full_reanalyze"
      when "ocr_retry"
        "receipt_analysis.ocr_retry"
      when "ai_retry"
        "receipt_analysis.ai_retry"
      when "finalize_retry"
        "receipt_analysis.finalize_retry"
      else
        "receipt_analysis.unknown_retry"
      end
    end

    def audit_metadata(result)
      metadata = {
        retry_type: audit_retry_type,
        parent_run_key: parent_run&.run_key,
        source: SOURCE
      }

      if result.success?
        metadata.merge!(
          new_run_key: result.run&.run_key,
          enqueued_job: result.enqueued_job&.name
        )
      else
        metadata[:failure_reason] = result.error_code
      end

      metadata.merge(reauthentication_metadata)
    end

    def audit_before_state
      @audit_before_state || build_audit_before_state
    end

    def build_audit_before_state
      {
        receipt_status: receipt&.status,
        active_run_key: active_run&.run_key,
        parent_run_status: parent_run&.status,
        parent_run_stage: parent_run&.stage
      }.compact
    end

    def audit_after_state(result)
      state = {
        receipt_status: receipt&.reload&.status
      }

      if result.success?
        state.merge!(
          new_run_key: result.run&.run_key,
          new_run_status: result.run&.status,
          enqueued_job: result.enqueued_job&.name
        )
      else
        state[:failure_reason] = result.error_code
      end

      state.compact
    end

    def audit_retry_type
      RETRY_TYPES.include?(retry_type) ? retry_type : "unknown_retry"
    end

    def reauthentication_metadata
      return {} unless fresh_passkey_reauthentication?

      {
        reauthenticated: true,
        reauthentication_method: reauthentication[:method],
        reauthenticated_at: reauthenticated_at
      }
    end

    def failure(error_code, error_message, run: nil)
      Result.new(
        run: run,
        enqueued_job: nil,
        retry_type: retry_type,
        error_code: error_code.to_s,
        error_message: error_message
      )
    end
  end
end
