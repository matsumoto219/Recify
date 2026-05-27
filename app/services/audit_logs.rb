module AuditLogs
  MAX_STRING_BYTES = 2_000
  MAX_ARRAY_ITEMS = 50

  BLOCKED_KEYS = %w[
    api_key
    attestation_object
    authenticator_data
    authorization
    blob_key
    challenge
    client_data_json
    cookie
    credential_id
    messages
    password
    prompt
    public_key
    raw_id
    raw_response
    raw_text
    response_body
    secret
    session
    signature
    signed_id
    token
    user_handle
  ].freeze

  BLOCKED_KEY_FRAGMENTS = %w[
    api_key
    attestation_object
    authenticator_data
    authorization
    blob_key
    challenge
    client_data_json
    cookie
    credential_id
    password
    prompt
    public_key
    raw_id
    raw_response
    raw_text
    response_body
    secret
    session
    signature
    signed_id
    token
    user_handle
  ].freeze

  ALLOWED_SENSITIVE_FRAGMENT_KEYS = %w[
    revoked_sessions_count
    sample_session_ids
    session_version
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
      AuditLog.create!(
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
