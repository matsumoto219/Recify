module SecurityEvents
  class Recorder
    AGGREGATION_WINDOW = 1.hour
    PAYLOAD_DIGEST_EMPTY = nil

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      event_type:,
      severity:,
      request: nil,
      actor_user: nil,
      ip_address: nil,
      user_agent: nil,
      request_id: nil,
      path: nil,
      method: nil,
      field_name: nil,
      matched_rule: nil,
      payload: nil,
      payload_excerpt: nil,
      metadata: {},
      occurred_at: Time.current
    )
      @event_type = event_type
      @severity = severity
      @request = request
      @actor_user = actor_user
      @ip_address = ip_address
      @user_agent = user_agent
      @request_id = request_id
      @path = path
      @method = method
      @field_name = field_name
      @matched_rule = matched_rule
      @payload = payload
      @payload_excerpt = payload_excerpt
      @metadata = metadata
      @occurred_at = occurred_at || Time.current
    end

    def call
      SecurityEvent.transaction do
        existing = aggregation_candidate

        if existing
          existing.with_lock do
            existing.count += 1
            existing.last_seen_at = occurred_at
            existing.metadata = merge_metadata(existing.metadata)
            existing.save!
          end
          existing
        else
          SecurityEvent.create!(event_attributes)
        end
      end
    end

    private

    attr_reader :event_type, :severity, :request, :actor_user, :ip_address, :user_agent,
                :request_id, :path, :method, :field_name, :matched_rule, :payload,
                :payload_excerpt, :metadata, :occurred_at

    def event_attributes
      {
        event_type: event_type,
        severity: severity,
        actor_user: actor_user_from_context,
        ip_address: ip_address_from_context,
        user_agent: user_agent_from_context,
        request_id: request_id_from_context,
        path: path_from_context,
        method: method_from_context,
        field_name: safe_string(field_name),
        matched_rule: safe_string(matched_rule),
        payload_excerpt: sanitized_payload_excerpt,
        payload_sha256: payload_digest,
        count: 1,
        first_seen_at: occurred_at,
        last_seen_at: occurred_at,
        metadata: sanitized_metadata
      }
    end

    def aggregation_candidate
      SecurityEvent
        .unresolved
        .where(
          event_type: event_type,
          ip_address: ip_address_from_context,
          path: path_from_context,
          payload_sha256: payload_digest,
          last_seen_at: AGGREGATION_WINDOW.ago..
        )
        .order(last_seen_at: :desc, id: :desc)
        .first
    end

    def actor_user_from_context
      return actor_user if actor_user.present?
      return unless request.respond_to?(:env)

      request.env["warden"]&.user(scope: :user, run_callbacks: false)
    rescue StandardError
      nil
    end

    def ip_address_from_context
      safe_string(ip_address || request_value(:remote_ip))
    end

    def user_agent_from_context
      safe_string(user_agent || request_value(:user_agent))
    end

    def request_id_from_context
      safe_string(request_id || request_value(:request_id))
    end

    def path_from_context
      safe_string(path || request_value(:path))
    end

    def method_from_context
      safe_string(method || request_value(:request_method))
    end

    def request_value(name)
      return unless request&.respond_to?(name)

      request.public_send(name)
    end

    def sanitized_payload_excerpt
      raw_value = payload_excerpt.presence || payload
      return if raw_value.blank?
      return if binary_payload?(raw_value)

      MetadataSanitizer.sanitize_text(raw_value.to_s)
    end

    def payload_digest
      excerpt = sanitized_payload_excerpt
      return PAYLOAD_DIGEST_EMPTY if excerpt.blank?

      Digest::SHA256.hexdigest(excerpt)
    end

    def sanitized_metadata
      MetadataSanitizer.call(metadata)
    end

    def merge_metadata(existing_metadata)
      existing_metadata.to_h.merge(sanitized_metadata) do |_key, old_value, new_value|
        new_value.presence || old_value
      end
    end

    def binary_payload?(value)
      string = value.to_s
      return true unless string.valid_encoding?
      return true if string.include?("\x00")

      false
    end

    def safe_string(value)
      return if value.blank?

      MetadataSanitizer.sanitize_text(value.to_s)
    end
  end
end
