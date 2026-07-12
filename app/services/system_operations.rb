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
    :ip_access_result,
    :security_ip_block,
    :receipt,
    :receipt_moderation_result,
    :error_code,
    :error_message,
    :error_details,
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
    def execute_receipt_analysis_retry(...)
      ReceiptAnalysisRetryExecutor.call(...)
    end

    def receipt_analysis_retry_confirmation_text
      ReceiptAnalysisRetryExecutor::CONFIRMATION_TEXT
    end

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

    def reset_setting(key:, actor:, reason:, request:, reauthentication:, confirmation: nil)
      SystemSettingResetExecutor.call(
        key: key,
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

    def execute_ip_access_operation(operation:, ip_address:, actor:, reason:, request:, reauthentication:, confirmation:, source_security_event: nil, expires_at: nil, rack_attack_target: nil)
      IpAccessOperationExecutor.call(
        operation: operation,
        ip_address: ip_address,
        actor: actor,
        reason: reason,
        request: request,
        reauthentication: reauthentication,
        confirmation: confirmation,
        source_security_event: source_security_event,
        expires_at: expires_at,
        rack_attack_target: rack_attack_target
      )
    end

    def execute_receipt_moderation_operation(operation:, receipt:, actor:, reason:, request:, reauthentication:, confirmation:, source_security_event: nil)
      ReceiptModerationExecutor.call(
        operation: operation,
        receipt: receipt,
        actor: actor,
        reason: reason,
        request: request,
        reauthentication: reauthentication,
        confirmation: confirmation,
        source_security_event: source_security_event
      )
    end

    def user_limit_update_confirmation_text
      UserLimitUpdateExecutor::CONFIRMATION_TEXT
    end
  end
end
