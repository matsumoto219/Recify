require "zlib"

module SecurityEvents
  class Recorder
    AGGREGATION_WINDOW = 1.hour
    STALE_CANDIDATE_RETRY_LIMIT = 1
    PAYLOAD_DIGEST_EMPTY = nil
    AGGREGATION_IDENTITY_FIELDS = %i[
      event_type
      severity
      actor_user_id
      ip_address
      path
      method
      field_name
      matched_rule
      payload_sha256
    ].freeze
    # These values must stay stable so every application process competes for the same locks.
    ADVISORY_LOCK_NAMESPACE = 992_996_087
    ADVISORY_LOCK_SQL = "SELECT pg_advisory_xact_lock($1, $2) IS NULL AS lock_result_ignored".freeze
    ADVISORY_LOCK_INTEGER = ActiveRecord::Type::Integer.new(limit: 4).freeze
    PROCESS_LOCK_STRIPES = Array.new(64) { Mutex.new }.freeze

    class << self
      def call(...)
        new(...).call
      end

      def aggregation_window
        SystemSettings.limit_for("security_events.aggregation_window_minutes").minutes
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        AGGREGATION_WINDOW
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
      lock_id = advisory_lock_id

      process_lock(lock_id).synchronize do
        record_with_lock(lock_id)
      end
    end

    private

    attr_reader :event_type, :severity, :request, :actor_user, :ip_address, :user_agent,
                :request_id, :path, :method, :field_name, :matched_rule, :payload,
                :payload_excerpt, :metadata, :occurred_at

    def record_with_lock(lock_id)
      stale_candidate_retries = 0

      begin
        SecurityEvent.transaction do
          acquire_database_lock(lock_id)
          existing = aggregation_candidate

          if existing
            existing.count += 1
            existing.first_seen_at, existing.last_seen_at = [
              existing.first_seen_at,
              existing.last_seen_at,
              new_event.first_seen_at,
              new_event.last_seen_at
            ].compact.minmax
            existing.metadata = merge_metadata(existing.metadata)
            existing.save!
            existing
          else
            new_event.save!
            new_event
          end
        end
      rescue ActiveRecord::RecordNotFound
        stale_candidate_retries += 1
        retry if stale_candidate_retries <= STALE_CANDIDATE_RETRY_LIMIT

        raise
      end
    end

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

    def new_event
      @new_event ||= SecurityEvent.new(event_attributes).tap(&:valid?)
    end

    def aggregation_candidate
      SecurityEvent
        .unresolved
        .where(aggregation_identity)
        .where(last_seen_at: self.class.aggregation_window.ago..)
        .order(last_seen_at: :desc, id: :desc)
        .lock
        .first
    end

    def aggregation_identity
      @aggregation_identity ||= AGGREGATION_IDENTITY_FIELDS.index_with do |attribute|
        new_event.public_send(attribute)
      end
    end

    def advisory_lock_id
      values = AGGREGATION_IDENTITY_FIELDS.map { |attribute| new_event.public_send(attribute).as_json }
      unsigned = Zlib.crc32(values.to_json)
      unsigned >= (2**31) ? unsigned - (2**32) : unsigned
    end

    def process_lock(lock_id)
      PROCESS_LOCK_STRIPES.fetch(lock_id % PROCESS_LOCK_STRIPES.length)
    end

    def acquire_database_lock(lock_id)
      binds = [
        ActiveRecord::Relation::QueryAttribute.new(
          "namespace",
          ADVISORY_LOCK_NAMESPACE,
          ADVISORY_LOCK_INTEGER
        ),
        ActiveRecord::Relation::QueryAttribute.new("lock_id", lock_id, ADVISORY_LOCK_INTEGER)
      ]

      SecurityEvent.connection.exec_query(
        ADVISORY_LOCK_SQL,
        "SecurityEvents::Recorder",
        binds,
        prepare: true
      )
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
      Recify::RequestPathSanitizer.sanitize(
        path || request_value(:path),
        max_length: SecurityEvent::PATH_MAX_LENGTH
      )
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
      existing_metadata.to_h.merge(new_event.metadata.to_h) do |_key, old_value, new_value|
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
