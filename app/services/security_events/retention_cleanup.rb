module SecurityEvents
  class RetentionCleanup
    DEFAULT_LIMIT = 1000
    SAMPLE_EVENT_ID_LIMIT = 20
    ORPHAN_IP_ACTION_RETENTION_SEVERITY = "medium"

    RETENTIONS = {
      "critical" => 180.days,
      "high" => 180.days,
      "medium" => 90.days,
      "low" => 30.days
    }.freeze
    RETENTION_SETTING_KEYS = {
      "critical" => "retention.security_events_critical_days",
      "high" => "retention.security_events_high_days",
      "medium" => "retention.security_events_medium_days",
      "low" => "retention.security_events_low_days"
    }.freeze

    class << self
      def call(dry_run: true, now: Time.current, limit: DEFAULT_LIMIT)
        new(dry_run: dry_run, now: now, limit: limit).call
      end
    end

    def initialize(dry_run:, now:, limit:)
      @dry_run = normalize_boolean(dry_run)
      @now = now || Time.current
      @limit = normalize_limit(limit)
      @retentions = SecurityEvent::SEVERITIES.index_with { |severity| retention_for(severity) }
      @retention_cutoffs = @retentions.transform_values { |retention| @now - retention }
    end

    def call
      records = target_records
      orphan_ip_actions = target_orphan_ip_actions(remaining_limit: limit - records.size)
      event_ids = records.map(&:id)

      result = {
        dry_run: dry_run,
        expired_count: event_ids.size,
        expired_ip_action_count: expired_ip_action_count(records) + orphan_ip_actions.size,
        deleted_count: 0,
        deleted_ip_action_count: 0,
        skipped_count: 0,
        failed_count: 0,
        sample_event_ids: event_ids.first(SAMPLE_EVENT_ID_LIMIT),
        retentions: retentions_in_days,
        cutoffs: cutoff_metadata,
        errors: []
      }

      return result if dry_run

      delete_candidates!(records, result)
      delete_orphan_ip_action_candidates!(orphan_ip_actions, result)
      result
    end

    private

    attr_reader :dry_run, :now, :limit, :retentions, :retention_cutoffs

    def target_records
      remaining = limit
      records = []

      SecurityEvent::SEVERITIES.each do |severity|
        break if remaining <= 0

        severity_records = relation_for(severity)
          .order(last_seen_at: :asc, id: :asc)
          .limit(remaining)
          .to_a
        records.concat(severity_records)
        remaining -= severity_records.size
      end

      records
    end

    def relation_for(severity)
      cutoff = cutoff_for(severity)
      exclude_protected_references(
        SecurityEvent.where(severity: severity, last_seen_at: ..cutoff),
        cutoff: cutoff
      )
    end

    def target_orphan_ip_actions(remaining_limit:)
      return [] unless remaining_limit.positive?

      SecurityIpAction
        .where(source: "rack_attack", source_security_event_id: nil, security_ip_block_id: nil)
        .where(last_seen_at: ..cutoff_for(ORPHAN_IP_ACTION_RETENTION_SEVERITY))
        .where("expires_at IS NULL OR expires_at <= ?", now)
        .where.not(status: "active", expires_at: nil)
        .order(last_seen_at: :asc, id: :asc)
        .limit(remaining_limit)
        .to_a
    end

    def cutoff_for(severity)
      retention_cutoffs.fetch(severity.to_s)
    end

    def cutoff_metadata
      RETENTIONS.each_with_object({}) do |(severity, _retention), values|
        values[severity] = cutoff_for(severity).iso8601
      end
    end

    def retentions_in_days
      RETENTIONS.keys.index_with { |severity| retentions.fetch(severity) / 1.day }
    end

    def retention_for(severity)
      key = RETENTION_SETTING_KEYS.fetch(severity.to_s)
      SystemSettings.limit_for(key).days
    rescue KeyError, SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      RETENTIONS.fetch(severity.to_s)
    end

    def exclude_protected_references(relation, cutoff:)
      relation
        .where.not(
          id: Receipt
            .where.not(quarantine_source_security_event_id: nil)
            .select(:quarantine_source_security_event_id)
        )
        .where.not(
          id: SecurityIpAction
            .where.not(source_security_event_id: nil)
            .where(protected_ip_action_condition, cutoff: cutoff, now: now)
            .select(:source_security_event_id)
        )
        .where.not(
          id: SecurityIpBlock
            .where.not(source_security_event_id: nil)
            .select(:source_security_event_id)
        )
    end

    def delete_candidates!(candidates, result)
      candidates.each do |candidate|
        outcome, deleted_ip_action_count = SecurityEvent.transaction(requires_new: true) do
          event = SecurityEvent.lock.find_by(id: candidate.id)
          next [ :skipped, 0 ] unless event

          ip_actions = SecurityIpAction
            .where(source_security_event_id: event.id)
            .order(:id)
            .lock
            .to_a
          next [ :skipped, 0 ] unless deletable_now?(event, ip_actions: ip_actions)

          action_ids = ip_actions.map(&:id)
          deleted_actions = SecurityIpAction.where(id: action_ids).delete_all
          event.delete
          [ :deleted, deleted_actions ]
        end

        result[outcome == :deleted ? :deleted_count : :skipped_count] += 1
        result[:deleted_ip_action_count] += deleted_ip_action_count
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << { event_id: candidate&.id, error_class: e.class.name }
      end
    end

    def delete_orphan_ip_action_candidates!(candidates, result)
      cutoff = cutoff_for(ORPHAN_IP_ACTION_RETENTION_SEVERITY)

      candidates.each do |candidate|
        outcome = SecurityIpAction.transaction(requires_new: true) do
          action = SecurityIpAction.lock.find_by(id: candidate.id)
          next :skipped unless action &&
            action.source_security_event_id.nil? &&
            deletable_ip_action?(action, cutoff: cutoff)

          action.delete
          :deleted
        end

        if outcome == :deleted
          result[:deleted_ip_action_count] += 1
        else
          result[:skipped_count] += 1
        end
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << { security_ip_action_id: candidate&.id, error_class: e.class.name }
      end
    end

    def deletable_now?(event, ip_actions:)
      cutoff = retention_cutoffs[event.severity]
      cutoff.present? &&
        event.last_seen_at <= cutoff &&
        !receipt_or_block_reference?(event.id) &&
        ip_actions.all? { |action| deletable_ip_action?(action, cutoff: cutoff) }
    end

    def receipt_or_block_reference?(event_id)
      Receipt.exists?(quarantine_source_security_event_id: event_id) ||
        SecurityIpBlock.exists?(source_security_event_id: event_id)
    end

    def protected_ip_action_condition
      <<~SQL.squish
        security_ip_actions.source <> 'rack_attack'
        OR security_ip_actions.last_seen_at > :cutoff
        OR security_ip_actions.expires_at > :now
        OR (security_ip_actions.status = 'active' AND security_ip_actions.expires_at IS NULL)
        OR security_ip_actions.security_ip_block_id IS NOT NULL
      SQL
    end

    def expired_ip_action_count(records)
      cutoff_by_event_id = records.to_h { |event| [ event.id, cutoff_for(event.severity) ] }
      return 0 if cutoff_by_event_id.empty?

      SecurityIpAction
        .where(source_security_event_id: cutoff_by_event_id.keys)
        .to_a
        .count do |action|
          deletable_ip_action?(action, cutoff: cutoff_by_event_id.fetch(action.source_security_event_id))
        end
    end

    def deletable_ip_action?(action, cutoff:)
      return false unless action.source == "rack_attack"
      return false if action.security_ip_block_id.present?
      return false if action.last_seen_at > cutoff
      return false if action.expires_at.present? && action.expires_at > now
      return false if action.status == "active" && action.expires_at.blank?

      true
    end

    def normalize_boolean(value)
      return true if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def normalize_limit(value)
      integer = value.to_i
      integer.positive? ? integer : DEFAULT_LIMIT
    end
  end
end
