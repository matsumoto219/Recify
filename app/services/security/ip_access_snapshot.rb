# frozen_string_literal: true

module Security
  class IpAccessSnapshot
    DEFAULT_RECENT_WINDOW = 24.hours
    MATCHED_RULE_LIMIT = 8

    class << self
      def call(ip_address:, recent_window: DEFAULT_RECENT_WINDOW)
        new(ip_address: ip_address, recent_window: recent_window).call
      end
    end

    def initialize(ip_address:, recent_window:)
      @raw_ip_address = ip_address
      @ip_address = IpAddress.normalize(ip_address)
      @recent_window = recent_window
    end

    def call
      return invalid_snapshot if ip_address.blank?

      {
        ip_address: ip_address,
        valid: true,
        blockable: IpAddress.blockable?(ip_address),
        non_blockable_reason: IpAddress.non_blockable_reason(ip_address),
        manual_block: manual_block_snapshot,
        rack_attack: rack_attack_snapshot,
        recent_security_events_count: recent_security_events.count,
        matched_rules: matched_rules
      }
    end

    private

    attr_reader :raw_ip_address, :ip_address, :recent_window

    def invalid_snapshot
      {
        ip_address: raw_ip_address.to_s,
        valid: false,
        blockable: false,
        non_blockable_reason: "invalid_ip",
        manual_block: {
          active: false,
          block: nil
        },
        rack_attack: {
          any_banned: false,
          targets: Security::RackAttackBanRegistry.banned_states(nil)
        },
        recent_security_events_count: 0,
        matched_rules: []
      }
    end

    def manual_block_snapshot
      block = SecurityIpBlock.currently_effective_for_ip(ip_address).order(created_at: :desc).first

      {
        active: block.present?,
        block: block ? block_payload(block) : nil
      }
    end

    def block_payload(block)
      {
        id: block.id,
        ip_address: block.ip_address.to_s,
        status: block.status,
        reason: block.reason,
        expires_at: block.expires_at,
        created_at: block.created_at,
        created_by_id: block.created_by_id,
        source_security_event_id: block.source_security_event_id
      }
    end

    def rack_attack_snapshot
      targets = Security::RackAttackBanRegistry.banned_states(ip_address)
      {
        any_banned: targets.values.any?,
        targets: targets
      }
    end

    def recent_security_events
      @recent_security_events ||= begin
        relation = SecurityEvent.where(ip_address: ip_address)
        relation.where(last_seen_at: recent_window.ago..)
      end
    end

    def matched_rules
      recent_security_events
        .where.not(matched_rule: [ nil, "" ])
        .group(:matched_rule)
        .order(Arel.sql("COUNT(*) DESC"), :matched_rule)
        .limit(MATCHED_RULE_LIMIT)
        .count
        .map { |rule, count| { matched_rule: rule, count: count } }
    end
  end
end
