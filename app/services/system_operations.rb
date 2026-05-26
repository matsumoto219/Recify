module SystemOperations
  Error = Class.new(StandardError)
  ValidationError = Class.new(Error)

  Result = Struct.new(
    :success,
    :operation,
    :cleanup_result,
    :audit_log,
    :error_code,
    :error_message,
    keyword_init: true
  ) do
    def success?
      success == true
    end

    def failure?
      !success?
    end
  end

  class << self
    def execute_receipt_analysis_cleanup(operation:, actor:, reason:, cutoff:, limit:, request:, reauthentication:)
      ReceiptAnalysisCleanupExecutor.call(
        operation: operation,
        actor: actor,
        reason: reason,
        cutoff: cutoff,
        limit: limit,
        request: request,
        reauthentication: reauthentication
      )
    end
  end
end
