module Admin
  class SecurityEventsQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    STATES = %w[open resolved ignored].freeze

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end

      def find(id:)
        new(id: id, limit: 1).call.records.first
      end

      def filter_options
        {
          event_types: SecurityEvent::EVENT_TYPES,
          severities: SecurityEvent::SEVERITIES,
          states: STATES
        }
      end
    end

    def initialize(
      id: nil,
      actor_user_id: nil,
      event_type: nil,
      severity: nil,
      ip_address: nil,
      request_id: nil,
      path: nil,
      matched_rule: nil,
      state: nil,
      created_from: nil,
      created_to: nil,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @id = id
      @actor_user_id = actor_user_id
      @event_type = event_type
      @severity = severity
      @ip_address = ip_address
      @request_id = request_id
      @path = path
      @matched_rule = matched_rule
      @state = state
      @created_from = created_from
      @created_to = created_to
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      events = relation.order(last_seen_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a

      Result.new(
        records: events.map { |security_event| build_record(security_event) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = SecurityEvent.includes(:actor_user)
      relation = filter_by_id(relation)
      relation = filter_by_column(relation, :actor_user_id, @actor_user_id)
      relation = filter_by_column(relation, :event_type, @event_type, SecurityEvent::EVENT_TYPES)
      relation = filter_by_column(relation, :severity, @severity, SecurityEvent::SEVERITIES)
      relation = filter_by_column(relation, :ip_address, @ip_address)
      relation = filter_by_column(relation, :request_id, @request_id)
      relation = filter_by_column(relation, :matched_rule, @matched_rule)
      relation = filter_by_path(relation)
      relation = filter_by_state(relation)
      filter_by_created_at(relation)
    end

    def filter_by_id(relation)
      ids = filter_values(@id).filter_map { |value| positive_integer(value) }
      return relation if ids.blank?

      relation.where(id: ids)
    end

    def filter_by_column(relation, column, value, allowlist = nil)
      values = filter_values(value)
      values &= allowlist if allowlist
      return relation if values.blank?

      relation.where(column => values)
    end

    def filter_by_path(relation)
      path = @path.to_s.strip
      return relation if path.blank?

      escaped = ActiveRecord::Base.sanitize_sql_like(path)
      relation.where("security_events.path LIKE ?", "%#{escaped}%")
    end

    def filter_by_state(relation)
      case @state.to_s
      when "open"
        relation.where(resolved_at: nil, ignored_at: nil)
      when "resolved"
        relation.where.not(resolved_at: nil)
      when "ignored"
        relation.where.not(ignored_at: nil)
      else
        relation
      end
    end

    def filter_by_created_at(relation)
      created_from = parse_time(@created_from)
      created_to = parse_time(@created_to)
      relation = relation.where(created_at: created_from..) if created_from
      relation = relation.where(created_at: ..created_to) if created_to
      relation
    end

    def build_record(security_event)
      {
        security_event: security_event,
        id: security_event.id,
        event_type: security_event.event_type,
        severity: security_event.severity,
        state: state_for(security_event),
        actor_user_id: security_event.actor_user_id,
        ip_address: security_event.ip_address&.to_s,
        user_agent: security_event.user_agent,
        request_id: security_event.request_id,
        path: security_event.path,
        method: security_event.method,
        field_name: security_event.field_name,
        matched_rule: security_event.matched_rule,
        payload_excerpt: security_event.payload_excerpt,
        payload_sha256: security_event.payload_sha256,
        count: security_event.count,
        first_seen_at: security_event.first_seen_at,
        last_seen_at: security_event.last_seen_at,
        resolved_at: security_event.resolved_at,
        ignored_at: security_event.ignored_at,
        metadata: security_event.metadata.is_a?(Hash) ? security_event.metadata : {},
        created_at: security_event.created_at
      }
    end

    def state_for(security_event)
      return "resolved" if security_event.resolved_at.present?
      return "ignored" if security_event.ignored_at.present?

      "open"
    end

    def filter_values(value)
      Array(value).filter_map do |item|
        normalized = item.to_s.strip
        normalized.presence
      end
    end

    def normalize_limit(value)
      normalized = value.to_i
      normalized = DEFAULT_LIMIT if normalized <= 0

      [ normalized, MAX_LIMIT ].min
    end

    def normalize_offset(value)
      [ value.to_i, 0 ].max
    end

    def positive_integer(value)
      integer = value.to_i
      integer.positive? ? integer : nil
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
