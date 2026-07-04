module AuditLogs
  MAX_STRING_BYTES = 2_000
  MAX_ARRAY_ITEMS = 50
  DEFAULT_RETENTION_CLEANUP_LIMIT = 1000

  BLOCKED_KEYS = (
    %w[
      access_token
      access-token
      api_key
      attestation_object
      authenticator_data
      authorization
      backup_code
      backup_codes
      blob_key
      challenge
      client_data_json
      client_secret
      code_digest
      cookie
      credential_id
      encrypted_totp_secret
      image
      image-payload
      image_payload
      messages
      one_time_password
      otp
      otp_attempt
      otpauth
      password
      prompt
      provisioning_uri
      public_key
      raw_id
      raw_response
      raw_text
      recovery_code
      recovery_codes
      refresh_token
      refresh-token
      response_body
      secret
      second_factor
      session
      set-cookie
      set_cookie
      signature
      signed_id
      token
      totp
      totp_code
      totp_secret
      two_factor
      user_handle
    ] + SensitiveMetadataKeys::PROVIDER_DETAIL_KEYS
  ).freeze

  BLOCKED_KEY_FRAGMENTS = %w[
    api_key
    attestation_object
    authenticator_data
    authorization
    backup_code
    blob_key
    challenge
    client_data_json
    code_digest
    cookie
    credential_id
    encrypted_totp_secret
    one_time_password
    otp_attempt
    otpauth
    password
    prompt
    provisioning_uri
    public_key
    raw_id
    raw_response
    raw_text
    recovery_code
    response_body
    secret
    second_factor
    session
    signature
    signed_id
    token
    totp
    two_factor
    user_handle
  ].freeze

  ALLOWED_SENSITIVE_FRAGMENT_KEYS = %w[
    backup_codes_count
    had_totp_after
    had_totp_before
    recovery_codes_count_after
    recovery_codes_count_before
    recovery_codes_count
    reset_password_sent_at_after
    reset_password_sent_at_before
    revoked_sessions_count
    sample_session_ids
    session_version
    session_version_after
    session_version_before
    totp_credential_present
    totp_enabled
    unused_recovery_codes_count_after
    unused_recovery_codes_count_before
    unused_recovery_codes_count
    user_sessions_count
  ].freeze

  class << self
    def record_admin_action!(actor:, action:, target: nil, target_uid: nil, reason: nil, outcome:, error_code: nil, metadata: {}, before_state: {}, after_state: {}, request: nil)
      record!(
        actor_user: actor,
        actor_kind: "admin",
        action: action,
        target: target,
        target_uid: target_uid,
        reason: reason,
        outcome: outcome,
        error_code: error_code,
        metadata: metadata,
        before_state: before_state,
        after_state: after_state,
        request: request
      )
    end

    def record_system_action!(action:, target: nil, target_uid: nil, reason: nil, outcome:, error_code: nil, metadata: {}, before_state: {}, after_state: {})
      record!(
        actor_user: nil,
        actor_kind: "system",
        action: action,
        target: target,
        target_uid: target_uid,
        reason: reason,
        outcome: outcome,
        error_code: error_code,
        metadata: metadata,
        before_state: before_state,
        after_state: after_state,
        request: nil
      )
    end

    def cleanup_retention(dry_run: true, categories: nil, now: Time.current, limit: DEFAULT_RETENTION_CLEANUP_LIMIT)
      RetentionCleanup.call(
        dry_run: dry_run,
        categories: categories,
        now: now,
        limit: limit
      )
    end

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), sanitized|
          key = key.to_s
          next if blocked_key?(key)

          sanitized[key] = sanitize(child)
        end
      when Array
        value.first(MAX_ARRAY_ITEMS).map { |child| sanitize(child) }
      when String
        truncate_string(value)
      when Symbol
        value.to_s
      when Time, Date, DateTime
        value.iso8601
      else
        json_scalar(value)
      end
    end

    private

    def record!(actor_user:, actor_kind:, action:, target:, target_uid:, reason:, outcome:, error_code:, metadata:, before_state:, after_state:, request:)
      audit_log = AuditLog.create!(
        actor_user: actor_user,
        actor_kind: actor_kind,
        action: action,
        target_type: target_type(target),
        target_id: target_id(target),
        target_uid: target_uid,
        reason: reason,
        outcome: outcome,
        error_code: error_code,
        metadata: sanitize_hash(metadata),
        before_state: sanitize_hash(before_state),
        after_state: sanitize_hash(after_state),
        request_id: request&.request_id,
        ip_address: request&.remote_ip,
        user_agent: request&.user_agent
      )
      SecurityEvents.record_admin_audit_burst!(audit_log)
      audit_log
    end

    def target_type(target)
      return if target.blank?

      target.class.respond_to?(:base_class) ? target.class.base_class.name : target.class.name
    end

    def target_id(target)
      return if target.blank?
      return unless target.respond_to?(:id)

      target.id
    end

    def sanitize_hash(value)
      sanitized = sanitize(value)
      sanitized.is_a?(Hash) ? sanitized : {}
    end

    def blocked_key?(key)
      normalized = key.to_s.downcase
      return false if ALLOWED_SENSITIVE_FRAGMENT_KEYS.include?(normalized)

      BLOCKED_KEYS.include?(normalized) ||
        BLOCKED_KEY_FRAGMENTS.any? { |fragment| normalized.include?(fragment) }
    end

    def truncate_string(value)
      return value if value.bytesize <= MAX_STRING_BYTES

      value.byteslice(0, MAX_STRING_BYTES).scrub
    end

    def json_scalar(value)
      case value
      when NilClass, TrueClass, FalseClass, Numeric
        value
      else
        value.to_s
      end
    end
  end
end
