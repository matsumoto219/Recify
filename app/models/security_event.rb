class SecurityEvent < ApplicationRecord
  EVENT_TYPES = %w[
    suspicious_payload
    sql_injection_attempt
    nosql_injection_attempt
    xss_attempt
    html_injection_attempt
    command_injection_attempt
    path_traversal_attempt
    ssrf_attempt
    open_redirect_attempt
    template_injection_attempt
    crlf_injection_attempt
    header_injection_attempt
    log_injection_attempt
    redos_attempt
    csv_injection_attempt
    xml_injection_attempt
    xpath_injection_attempt
    ldap_injection_attempt
    suspicious_file_upload
    mime_spoofing_attempt
    invalid_json_attempt
    json_injection_attempt
    schema_abuse_attempt
    prompt_injection_attempt
    ocr_text_injection_attempt
    parameter_tampering_attempt
    idor_attempt
    csrf_failure
    rate_limit_triggered
    invalid_upload
    external_service_repeated_failure
    admin_high_risk_burst
    system_settings_change_burst
    user_limits_override_burst
  ].freeze

  SEVERITIES = %w[low medium high critical].freeze
  PAYLOAD_EXCERPT_MAX_BYTES = 1_000
  PATH_MAX_LENGTH = 2048
  USER_AGENT_MAX_LENGTH = 1000
  METHOD_MAX_LENGTH = 16
  STRING_FIELD_MAX_LENGTH = 255

  SENSITIVE_KEY_PATTERN = /
    password|token|authorization|cookie|secret|api[_-]?key|access[_-]?token|
    refresh[_-]?token|totp|otp|recovery[_-]?code|backup[_-]?code|csrf|
    session|credential|challenge|raw[_-]?response|prompt|raw[_-]?text|image|
    source[_-]?text|normalized[_-]?text
  /ix

  belongs_to :actor_user,
             class_name: "User",
             optional: true

  before_validation :apply_defaults
  before_validation :normalize_strings
  before_validation :sanitize_metadata

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :first_seen_at, presence: true
  validates :last_seen_at, presence: true
  validates :payload_sha256, length: { is: 64 }, allow_blank: true
  validates :payload_excerpt, length: { maximum: PAYLOAD_EXCERPT_MAX_BYTES }, allow_blank: true
  validates :path, length: { maximum: PATH_MAX_LENGTH }, allow_blank: true
  validates :method, length: { maximum: METHOD_MAX_LENGTH }, allow_blank: true
  validates :user_agent, length: { maximum: USER_AGENT_MAX_LENGTH }, allow_blank: true
  validates :field_name, :matched_rule, :request_id, length: { maximum: STRING_FIELD_MAX_LENGTH }, allow_blank: true
  validate :metadata_is_hash

  scope :unresolved, -> { where(resolved_at: nil, ignored_at: nil) }

  private

  def apply_defaults
    now = Time.current
    self.first_seen_at ||= now
    self.last_seen_at ||= first_seen_at || now
    self.count ||= 1
    self.metadata ||= {}
  end

  def normalize_strings
    self.event_type = event_type.to_s.strip
    self.severity = severity.to_s.strip
    self.method = truncate_string(method.to_s.upcase.presence, METHOD_MAX_LENGTH)
    self.path = truncate_string(path.to_s.presence, PATH_MAX_LENGTH)
    self.user_agent = truncate_string(user_agent.to_s.presence, USER_AGENT_MAX_LENGTH)
    self.request_id = truncate_string(request_id.to_s.presence, STRING_FIELD_MAX_LENGTH)
    self.field_name = truncate_string(field_name.to_s.presence, STRING_FIELD_MAX_LENGTH)
    self.matched_rule = truncate_string(matched_rule.to_s.presence, STRING_FIELD_MAX_LENGTH)
    self.payload_excerpt = sanitized_payload_excerpt
    self.payload_sha256 = payload_sha256.to_s.presence
  end

  def sanitize_metadata
    return unless metadata.is_a?(Hash)

    self.metadata = SecurityEvents.sanitize_metadata(metadata)
  end

  def metadata_is_hash
    errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
  end

  def truncate_string(value, max_length)
    return if value.blank?

    value.to_s.first(max_length)
  end

  def sanitized_payload_excerpt
    value = payload_excerpt.to_s.presence
    return if value.blank?

    truncate_bytes(SecurityEvents.sanitize_text(value), PAYLOAD_EXCERPT_MAX_BYTES)
  end

  def truncate_bytes(value, max_bytes)
    return if value.blank?
    return value if value.bytesize <= max_bytes

    value.byteslice(0, max_bytes).scrub
  end
end
