# frozen_string_literal: true

module Admin
  class IpActionsQuery
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 50

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end
    end

    def initialize(ip_address:, limit: DEFAULT_LIMIT, offset: 0)
      @ip_address = ::Security.normalize_ip_address(ip_address)
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      actions = relation
        .includes(:actor_user, :source_security_event, :security_ip_block)
        .recent_first
        .limit(@limit)
        .offset(@offset)
        .to_a

      Result.new(
        records: actions.map { |action| build_record(action) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      return SecurityIpAction.none if @ip_address.blank?

      SecurityIpAction.where(ip_address: @ip_address)
    end

    def build_record(action)
      {
        id: action.id,
        ip_address: action.ip_address.to_s,
        action_type: action.action_type,
        source: action.source,
        status: action.display_status,
        matched_rule: action.matched_rule,
        count: action.count,
        first_seen_at: action.first_seen_at,
        last_seen_at: action.last_seen_at,
        expires_at: action.expires_at,
        reason: action.reason,
        actor_user: user_payload(action.actor_user),
        source_security_event: security_event_payload(action.source_security_event),
        security_ip_block: security_ip_block_payload(action.security_ip_block)
      }
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

    def security_ip_block_payload(block)
      return if block.blank?

      {
        id: block.id,
        status: block.status,
        expires_at: block.expires_at
      }
    end

    def normalize_limit(value)
      normalized = value.to_i
      normalized = DEFAULT_LIMIT if normalized <= 0

      [ normalized, MAX_LIMIT ].min
    end

    def normalize_offset(value)
      [ value.to_i, 0 ].max
    end
  end
end
