module Admin
  class AuditLogsQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end

      def filter_options
        {
          actor_kinds: AuditLog::ACTOR_KINDS,
          outcomes: AuditLog::OUTCOMES
        }
      end
    end

    def initialize(
      id: nil,
      actor_user_id: nil,
      actor_kind: nil,
      action: nil,
      outcome: nil,
      target_uid: nil,
      request_id: nil,
      error_code: nil,
      created_from: nil,
      created_to: nil,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @id = id
      @actor_user_id = actor_user_id
      @actor_kind = actor_kind
      @action = action
      @outcome = outcome
      @target_uid = target_uid
      @request_id = request_id
      @error_code = error_code
      @created_from = created_from
      @created_to = created_to
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      logs = relation.order(created_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a

      Result.new(
        records: logs.map { |audit_log| build_record(audit_log) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = AuditLog.includes(:actor_user)
      relation = filter_by_id(relation)
      relation = filter_by_column(relation, :actor_user_id, @actor_user_id)
      relation = filter_by_column(relation, :actor_kind, @actor_kind)
      relation = filter_by_column(relation, :action, @action)
      relation = filter_by_column(relation, :outcome, @outcome)
      relation = filter_by_column(relation, :target_uid, @target_uid)
      relation = filter_by_column(relation, :request_id, @request_id)
      relation = filter_by_column(relation, :error_code, @error_code)
      filter_by_created_at(relation)
    end

    def filter_by_id(relation)
      ids = filter_values(@id).filter_map { |value| positive_integer(value) }
      return relation if ids.blank?

      relation.where(id: ids)
    end

    def filter_by_column(relation, column, value)
      values = filter_values(value)
      return relation if values.blank?

      relation.where(column => values)
    end

    def filter_by_created_at(relation)
      created_from = parse_time(@created_from)
      created_to = parse_time(@created_to)
      relation = relation.where(created_at: created_from..) if created_from
      relation = relation.where(created_at: ..created_to) if created_to
      relation
    end

    def build_record(audit_log)
      {
        audit_log: audit_log,
        id: audit_log.id,
        actor: {
          kind: audit_log.actor_kind,
          user_id: audit_log.actor_user_id
        },
        action: audit_log.action,
        outcome: audit_log.outcome,
        error_code: audit_log.error_code,
        target_type: audit_log.target_type,
        target_id: audit_log.target_id,
        target_uid: audit_log.target_uid,
        reason: audit_log.reason,
        request_id: audit_log.request_id,
        ip_address: audit_log.ip_address&.to_s,
        user_agent: audit_log.user_agent,
        metadata: sanitize(audit_log.metadata),
        before_state: sanitize(audit_log.before_state),
        after_state: sanitize(audit_log.after_state),
        created_at: audit_log.created_at
      }
    end

    def sanitize(value)
      sanitized = AuditLogs.sanitize(value)
      sanitized.is_a?(Hash) ? sanitized : {}
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
