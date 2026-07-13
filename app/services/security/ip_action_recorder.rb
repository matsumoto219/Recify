# frozen_string_literal: true

module Security
  class IpActionRecorder
    AGGREGATION_WINDOW = 1.hour
    RACK_ATTACK_BANTIME = 30.minutes

    AUTO_RULES = {
      "fail2ban/scanner_paths" => {
        action_type: "scanner_restriction"
      },
      "adaptive/scanner_restrictions" => {
        action_type: "scanner_restriction"
      },
      "fail2ban/admin_probes" => {
        action_type: "admin_probe_restriction",
        status: "active",
        expires_in: Rack::Attack::ADMIN_PROBE_BANTIME
      },
      "fail2ban/active_storage_direct_uploads" => {
        action_type: "direct_upload_probe_restriction",
        status: "active",
        expires_in: RACK_ATTACK_BANTIME
      }
    }.freeze

    SKIPPED_RACK_ATTACK_RULES = %w[manual/ip_blocks].freeze

    class << self
      def call(...)
        new(...).call
      end

      def record_rate_limit(request:, matched_rule:, security_event: nil, retry_after: nil, metadata: {})
        rule = matched_rule.to_s.presence || "rate_limit"
        return if SKIPPED_RACK_ATTACK_RULES.include?(rule)

        config = AUTO_RULES.fetch(rule, {})
        action_type = config.fetch(:action_type, "rate_limit_triggered")
        raw_metadata = metadata.respond_to?(:to_h) ? metadata.to_h.symbolize_keys : {}
        status = action_status(config: config, metadata: raw_metadata)
        expires_at = expires_at_for(config: config, retry_after: retry_after, metadata: raw_metadata)

        call(
          ip_address: request_ip(request),
          action_type: action_type,
          source: "rack_attack",
          status: status,
          matched_rule: rule,
          source_security_event: security_event,
          count: 1,
          first_seen_at: security_event&.first_seen_at,
          last_seen_at: security_event&.last_seen_at,
          expires_at: expires_at,
          metadata: rack_attack_metadata(raw_metadata, retry_after: retry_after),
          aggregate: true
        )
      rescue StandardError => e
        Rails.logger.warn("[Security::IpActionRecorder] rate_limit_record_failed class=#{e.class.name}")
        nil
      end

      def record_operation(operation:, result:, actor:, reason:, source_security_event: nil, audit_log: nil)
        config = operation_config(operation)
        return if config.blank?

        block = security_ip_block_from(result)
        call(
          ip_address: result.respond_to?(:ip_address) ? result.ip_address : block&.ip_address,
          action_type: config.fetch(:action_type),
          source: "manual_admin",
          status: config.fetch(:status),
          matched_rule: config.fetch(:matched_rule),
          source_security_event: source_security_event,
          security_ip_block: block,
          actor_user: actor,
          reason: reason,
          expires_at: operation_expires_at(operation: operation, result: result, block: block),
          metadata: operation_metadata(operation: operation, result: result, audit_log: audit_log),
          aggregate: false
        )
      rescue StandardError => e
        Rails.logger.warn("[Security::IpActionRecorder] operation_record_failed class=#{e.class.name}")
        nil
      end

      private

      def request_ip(request)
        raw = request.respond_to?(:remote_ip) ? request.remote_ip : request.try(:ip)
        IpAddress.normalize(raw)
      end

      def action_status(config:, metadata:)
        return metadata[:active] == true ? "active" : "observed" if scanner_restriction_config?(config)

        config.fetch(:status, "observed")
      end

      def expires_at_for(config:, retry_after:, metadata:)
        return metadata[:expires_at] if scanner_restriction_config?(config) && metadata[:active] == true

        expires_in = config[:expires_in]
        return expires_in.from_now if expires_in
        return retry_after.to_i.seconds.from_now if retry_after.to_i.positive?

        nil
      end

      def rack_attack_metadata(metadata, retry_after:)
        raw = metadata.respond_to?(:to_h) ? metadata.to_h : {}
        raw.symbolize_keys.slice(
          :matched,
          :limit,
          :period,
          :retry_after,
          :active,
          :tier,
          :strike_count,
          :duration_seconds
        ).merge(
          retry_after: retry_after,
          category: "ip_access"
        ).compact
      end

      def scanner_restriction_config?(config)
        config[:action_type] == "scanner_restriction"
      end

      def operation_config(operation)
        {
          "manual_ip_block" => {
            action_type: "manual_ip_block",
            status: "active",
            matched_rule: "manual/ip_blocks"
          },
          "manual_ip_unblock" => {
            action_type: "manual_ip_unblock",
            status: "revoked",
            matched_rule: "manual/ip_blocks"
          },
          "rack_attack_ip_ban_reset" => {
            action_type: "rack_attack_ban_reset",
            status: "reset",
            matched_rule: "rack_attack/reset"
          }
        }.fetch(operation.to_s, nil)
      end

      def security_ip_block_from(result)
        result.respond_to?(:block) ? result.block : nil
      end

      def operation_expires_at(operation:, result:, block:)
        return block&.expires_at if operation.to_s == "manual_ip_block"
        return if operation.to_s != "rack_attack_ip_ban_reset"

        Time.current
      end

      def operation_metadata(operation:, result:, audit_log:)
        metadata = {
          operation: operation,
          audit_log_id: audit_log&.id
        }

        if operation.to_s == "rack_attack_ip_ban_reset"
          metadata[:target] = result.target if result.respond_to?(:target)
          metadata[:reset_targets] = result.reset_targets if result.respond_to?(:reset_targets)
        end

        metadata.compact
      end
    end

    def initialize(
      ip_address:,
      action_type:,
      source:,
      status:,
      matched_rule: nil,
      source_security_event: nil,
      security_ip_block: nil,
      actor_user: nil,
      reason: nil,
      count: 1,
      first_seen_at: nil,
      last_seen_at: nil,
      expires_at: nil,
      metadata: {},
      aggregate: true
    )
      @ip_address = IpAddress.normalize(ip_address)
      @action_type = action_type.to_s
      @source = source.to_s
      @status = status.to_s
      @matched_rule = matched_rule.to_s.presence
      @source_security_event = source_security_event
      @security_ip_block = security_ip_block
      @actor_user = actor_user
      @reason = reason.to_s.presence
      @count = count.to_i.positive? ? count.to_i : 1
      @first_seen_at = first_seen_at || Time.current
      @last_seen_at = last_seen_at || @first_seen_at
      @expires_at = expires_at
      @metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}
      @aggregate = aggregate == true
    end

    def call
      return if ip_address.blank?

      if aggregate
        record_aggregated!
      else
        SecurityIpAction.create!(attributes)
      end
    end

    private

    attr_reader :ip_address, :action_type, :source, :status, :matched_rule,
                :source_security_event, :security_ip_block, :actor_user, :reason,
                :count, :first_seen_at, :last_seen_at, :expires_at, :metadata, :aggregate

    def record_aggregated!
      existing = aggregation_candidate

      if existing
        existing.with_lock do
          existing.count += count
          existing.last_seen_at = [ existing.last_seen_at, last_seen_at ].compact.max
          existing.first_seen_at = [ existing.first_seen_at, first_seen_at ].compact.min
          existing.expires_at = later_time(existing.expires_at, expires_at)
          existing.source_security_event ||= source_security_event
          existing.metadata = existing.metadata.to_h.merge(metadata)
          existing.save!
        end
        existing
      else
        SecurityIpAction.create!(attributes)
      end
    end

    def aggregation_candidate
      relation = SecurityIpAction.where(
        ip_address: ip_address,
        action_type: action_type,
        source: source,
        matched_rule: matched_rule,
        status: status
      )
      relation = relation.where(last_seen_at: AGGREGATION_WINDOW.ago..)
      relation.recent_first.first
    end

    def attributes
      {
        ip_address: ip_address,
        action_type: action_type,
        source: source,
        status: status,
        matched_rule: matched_rule,
        source_security_event: source_security_event,
        security_ip_block: security_ip_block,
        actor_user: actor_user,
        reason: reason,
        count: count,
        first_seen_at: first_seen_at,
        last_seen_at: last_seen_at,
        expires_at: expires_at,
        metadata: metadata
      }
    end

    def later_time(left, right)
      return left if right.blank?
      return right if left.blank?

      [ left, right ].max
    end
  end
end
