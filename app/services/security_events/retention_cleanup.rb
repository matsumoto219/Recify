module SecurityEvents
  class RetentionCleanup
    DEFAULT_LIMIT = 1000
    SAMPLE_EVENT_ID_LIMIT = 20

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
      event_ids = records.map(&:id)

      result = {
        dry_run: dry_run,
        expired_count: event_ids.size,
        deleted_count: 0,
        skipped_count: 0,
        failed_count: 0,
        sample_event_ids: event_ids.first(SAMPLE_EVENT_ID_LIMIT),
        retentions: retentions_in_days,
        cutoffs: cutoff_metadata,
        errors: []
      }

      return result if dry_run

      delete_candidates!(records, result)
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
      exclude_referenced_events(SecurityEvent.where(severity: severity, last_seen_at: ..cutoff))
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

    def exclude_referenced_events(relation)
      relation
        .where.not(
          id: Receipt
            .where.not(quarantine_source_security_event_id: nil)
            .select(:quarantine_source_security_event_id)
        )
        .where.not(
          id: SecurityIpAction
            .where.not(source_security_event_id: nil)
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
        outcome = SecurityEvent.transaction(requires_new: true) do
          event = SecurityEvent.lock.find_by(id: candidate.id)
          next :skipped unless event && deletable_now?(event)

          event.delete
          :deleted
        end

        result[outcome == :deleted ? :deleted_count : :skipped_count] += 1
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << { event_id: candidate&.id, error_class: e.class.name }
      end
    end

    def deletable_now?(event)
      cutoff = retention_cutoffs[event.severity]
      cutoff.present? && event.last_seen_at <= cutoff && !referenced?(event.id)
    end

    def referenced?(event_id)
      Receipt.exists?(quarantine_source_security_event_id: event_id) ||
        SecurityIpAction.exists?(source_security_event_id: event_id) ||
        SecurityIpBlock.exists?(source_security_event_id: event_id)
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
