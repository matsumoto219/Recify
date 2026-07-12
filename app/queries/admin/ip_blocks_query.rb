module Admin
  class IpBlocksQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    STATES = %w[active revoked expired].freeze
    RECENT_WINDOW = 24.hours

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
          states: STATES
        }
      end
    end

    def initialize(
      id: nil,
      status: nil,
      ip_address: nil,
      created_by_id: nil,
      source_security_event_id: nil,
      expires_before: nil,
      expires_after: nil,
      created_from: nil,
      created_to: nil,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @id = id
      @status = status
      @ip_address = ip_address
      @created_by_id = created_by_id
      @source_security_event_id = source_security_event_id
      @expires_before = expires_before
      @expires_after = expires_after
      @created_from = created_from
      @created_to = created_to
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      blocks = relation.order(created_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a
      recent_counts = recent_security_event_counts(blocks)

      Result.new(
        records: blocks.map { |block| build_record(block, recent_counts) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = SecurityIpBlock.includes(:created_by, :revoked_by, :source_security_event)
      relation = filter_by_id(relation)
      relation = filter_by_status(relation)
      relation = filter_by_ip_address(relation)
      relation = filter_by_positive_integer(relation, :created_by_id, @created_by_id)
      relation = filter_by_positive_integer(relation, :source_security_event_id, @source_security_event_id)
      relation = filter_by_time(relation, :expires_at, from: @expires_after, to: @expires_before)
      filter_by_time(relation, :created_at, from: @created_from, to: @created_to)
    end

    def filter_by_id(relation)
      ids = filter_values(@id).filter_map { |value| positive_integer(value) }
      return relation if ids.blank?

      relation.where(id: ids)
    end

    def filter_by_status(relation)
      states = filter_values(@status) & STATES
      return relation if states.blank?

      states.map { |state| status_relation(relation, state) }.reduce(&:or)
    end

    def status_relation(relation, state)
      case state
      when "active"
        relation.where(status: "active").where("expires_at IS NULL OR expires_at > ?", Time.current)
      when "expired"
        relation.where(status: "active").where.not(expires_at: nil).where(expires_at: ..Time.current)
      when "revoked"
        relation.where(status: "revoked")
      end
    end

    def filter_by_ip_address(relation)
      values = filter_values(@ip_address)
      return relation if values.blank?

      normalized = values.filter_map { |value| ::Security.normalize_ip_address(value) }
      return relation.none if normalized.blank?

      relation.where(ip_address: normalized)
    end

    def filter_by_positive_integer(relation, column, value)
      ids = filter_values(value).filter_map { |item| positive_integer(item) }
      return relation if ids.blank?

      relation.where(column => ids)
    end

    def filter_by_time(relation, column, from:, to:)
      from_time = parse_time(from)
      to_time = parse_time(to)
      relation = relation.where(column => from_time..) if from_time
      relation = relation.where(column => ..to_time) if to_time
      relation
    end

    def build_record(block, recent_counts)
      ip_address = block.ip_address.to_s
      rack_attack_targets = ::Security.rack_attack_banned_states(ip_address)

      {
        security_ip_block: block,
        id: block.id,
        ip_address: ip_address,
        status: block.status,
        state: state_for(block),
        unblockable: block.currently_effective?,
        reason: block.reason,
        revoked_reason: block.revoked_reason,
        expires_at: block.expires_at,
        created_at: block.created_at,
        updated_at: block.updated_at,
        revoked_at: block.revoked_at,
        created_by: user_payload(block.created_by),
        revoked_by: user_payload(block.revoked_by),
        source_security_event: security_event_payload(block.source_security_event),
        recent_security_events_count: recent_counts.fetch(ip_address, 0),
        rack_attack: {
          any_banned: rack_attack_targets.values.any?,
          targets: rack_attack_targets
        },
        audit_target_uid: "ip:#{ip_address}"
      }
    end

    def state_for(block)
      return "revoked" if block.revoked?
      return "expired" if block.expires_at.present? && block.expires_at <= Time.current

      "active"
    end

    def user_payload(user)
      return if user.blank?

      {
        id: user.id,
        email: user.email
      }
    end

    def security_event_payload(security_event)
      return if security_event.blank?

      {
        id: security_event.id,
        event_type: security_event.event_type,
        matched_rule: security_event.matched_rule,
        last_seen_at: security_event.last_seen_at
      }
    end

    def recent_security_event_counts(blocks)
      ip_addresses = blocks.map { |block| block.ip_address.to_s }.uniq
      return {} if ip_addresses.blank?

      SecurityEvent
        .where(ip_address: ip_addresses, last_seen_at: RECENT_WINDOW.ago..)
        .group(:ip_address)
        .count
        .transform_keys(&:to_s)
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
    rescue ArgumentError, TypeError
      nil
    end
  end
end
