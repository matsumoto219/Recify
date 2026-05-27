module SystemOperations
  Error = Class.new(StandardError)
  ValidationError = Class.new(Error)

  Result = Struct.new(
    :success,
    :operation,
    :cleanup_result,
    :setting,
    :value,
    :before_state,
    :after_state,
    :audit_log,
    :user_limit_override,
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

    def update_setting(key:, value:, actor:, reason:, request:, reauthentication:, confirmation: nil)
      SystemSettingUpdateExecutor.call(
        key: key,
        value: value,
        actor: actor,
        reason: reason,
        request: request,
        reauthentication: reauthentication,
        confirmation: confirmation
      )
    end

    def execute_user_operation(operation:, user:, actor:, reason:, request:, reauthentication:, confirmation:)
      UserOperationExecutor.call(
        operation: operation,
        user: user,
        actor: actor,
        reason: reason,
        request: request,
        reauthentication: reauthentication,
        confirmation: confirmation
      )
    end

    def update_user_limit(user:, key:, value:, enabled:, expires_at:, actor:, reason:, request:, reauthentication:, confirmation:)
      UserLimitUpdateExecutor.call(
        user: user,
        key: key,
        value: value,
        enabled: enabled,
        expires_at: expires_at,
        actor: actor,
        reason: reason,
        request: request,
        reauthentication: reauthentication,
        confirmation: confirmation
      )
    end
  end
end
