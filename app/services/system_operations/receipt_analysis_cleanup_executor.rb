module SystemOperations
  class ReceiptAnalysisCleanupExecutor
    OPERATIONS = {
      "stale_cleanup" => {
        action: "receipt_analysis_runs.cleanup_stale.execute",
        limit_default: 100,
        limit_max: 100
      },
      "retention_cleanup" => {
        action: "receipt_analysis_runs.cleanup_expired.execute",
        limit_default: 1000,
        limit_max: 1000
      }
    }.freeze

    SAMPLE_RUN_KEY_LIMIT = 20

    class << self
      def call(operation:, actor:, reason:, cutoff:, limit:, request:, reauthentication:)
        new(
          operation: operation,
          actor: actor,
          reason: reason,
          cutoff: cutoff,
          limit: limit,
          request: request,
          reauthentication: reauthentication
        ).call
      end
    end

    def initialize(operation:, actor:, reason:, cutoff:, limit:, request:, reauthentication:)
      @operation = operation.to_s
      @actor = actor
      @reason = reason.to_s.strip
      @raw_cutoff = cutoff
      @limit = limit
      @request = request
      @reauthentication = reauthentication.to_h.symbolize_keys
    end

    def call
      validate!

      cleanup_result = nil
      audit_log = nil

      AuditLog.transaction do
        cleanup_result = execute_cleanup
        audit_log = record_success_audit!(cleanup_result)
      end

      Result.new(
        success: true,
        operation: operation,
        cleanup_result: cleanup_result,
        audit_log: audit_log
      )
    rescue StandardError => e
      audit_log = record_failed_audit!(e)

      Result.new(
        success: false,
        operation: operation,
        cleanup_result: nil,
        audit_log: audit_log,
        error_code: error_code_for(e),
        error_message: e.message
      )
    end

    private

    attr_reader :operation, :actor, :reason, :raw_cutoff, :limit, :request, :reauthentication

    def validate!
      raise ValidationError, "unknown_operation" unless operation_config
      raise ValidationError, "actor_required" unless actor
      raise ValidationError, "reason_required" if reason.blank?
      raise ValidationError, "reauthentication_required" unless fresh_passkey_reauthentication?

      cutoff
    end

    def execute_cleanup
      case operation
      when "stale_cleanup"
        Receipts::Processing.cleanup_stale(cutoff: cutoff, limit: normalized_limit, dry_run: false)
      when "retention_cleanup"
        Receipts::Processing.cleanup_expired(cutoff: cutoff, limit: normalized_limit, dry_run: false)
      end
    end

    def record_success_audit!(cleanup_result)
      AuditLogs.record_admin_action!(
        actor: actor,
        action: operation_config.fetch(:action),
        reason: reason,
        outcome: "succeeded",
        metadata: audit_metadata(cleanup_result),
        request: request
      )
    end

    def record_failed_audit!(error)
      action = operation_config&.fetch(:action) || "system_operations.receipt_analysis_cleanup.unknown"

      AuditLogs.record_admin_action!(
        actor: actor,
        action: action,
        reason: reason.presence,
        outcome: "failed",
        error_code: error_code_for(error),
        metadata: failure_audit_metadata(error),
        request: request
      )
    end

    def audit_metadata(cleanup_result)
      {
        dry_run: false,
        cutoff: audit_time(cleanup_result[:cutoff] || cutoff),
        limit: cleanup_result[:limit] || normalized_limit,
        sample_run_keys: sample_run_keys(cleanup_result)
      }.merge(count_metadata(cleanup_result))
        .merge(reauthentication_metadata)
    end

    def failure_audit_metadata(error)
      {
        dry_run: false,
        cutoff: audit_time(cutoff_for_audit),
        limit: normalized_limit_for_audit,
        error_class: error.class.name,
        sample_run_keys: []
      }.merge(reauthentication_metadata)
    end

    def count_metadata(cleanup_result)
      if operation == "stale_cleanup"
        {
          stale_count: cleanup_result[:stale_count],
          failed_count: cleanup_result[:failed_count],
          canceled_count: cleanup_result[:canceled_count],
          skipped_count: cleanup_result[:skipped_count],
          stuck_processing_count: cleanup_result[:stuck_processing_count].to_i,
          stuck_processing_failed_count: cleanup_result[:stuck_processing_failed_count].to_i,
          stuck_processing_skipped_count: cleanup_result[:stuck_processing_skipped_count].to_i
        }
      else
        {
          expired_count: cleanup_result[:expired_count],
          deleted_count: cleanup_result[:deleted_count]
        }
      end
    end

    def reauthentication_metadata
      return {} unless fresh_passkey_reauthentication?

      {
        reauthenticated: true,
        reauthentication_method: reauthentication[:method],
        reauthenticated_at: reauthentication[:reauthenticated_at]
      }
    end

    def fresh_passkey_reauthentication?
      Admin.passkey_reauth_fresh?(reauthentication)
    end

    def operation_config
      OPERATIONS[operation]
    end

    def normalized_limit
      @normalized_limit ||= begin
        value = limit.blank? ? operation_config.fetch(:limit_default) : UserNumericInput.integer(limit)
        raise ValidationError, "invalid_limit" if value <= 0

        [ value, operation_config.fetch(:limit_max) ].min
      end
    rescue UserNumericInput::InvalidValue
      raise ValidationError, "invalid_limit"
    end

    def normalized_limit_for_audit
      return unless operation_config

      normalized_limit
    rescue ValidationError
      nil
    end

    def cutoff
      @cutoff ||= normalize_time(raw_cutoff)
    end

    def cutoff_for_audit
      cutoff
    rescue ValidationError
      nil
    end

    def normalize_time(value)
      raise ValidationError, "invalid_cutoff" if value.blank?

      normalized = if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        value
      elsif value.is_a?(Date) || value.is_a?(DateTime)
        value.to_time.in_time_zone
      else
        Time.zone.parse(value.to_s)
      end

      raise ValidationError, "invalid_cutoff" unless normalized
      raise ValidationError, "invalid_cutoff" if normalized > Time.current

      normalized
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_cutoff"
    end

    def sample_run_keys(cleanup_result)
      Array(cleanup_result[:records])
        .filter_map { |record| record[:run_key].presence }
        .first(SAMPLE_RUN_KEY_LIMIT)
    end

    def audit_time(value)
      return value.iso8601 if value.respond_to?(:iso8601)

      value
    end

    def error_code_for(error)
      return error.message if error.is_a?(ValidationError) && error.message.present?

      "cleanup_failed"
    end
  end
end
