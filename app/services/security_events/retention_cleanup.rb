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
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
      @now = now || Time.current
      @limit = normalize_limit(limit)
    end

    def call
      records = target_records
      event_ids = records.map(&:id)

      result = {
        dry_run: dry_run,
        expired_count: event_ids.size,
        deleted_count: 0,
        sample_event_ids: event_ids.first(SAMPLE_EVENT_ID_LIMIT),
        retentions: retentions_in_days,
        cutoffs: cutoffs,
        errors: []
      }

      return result if dry_run

      result[:deleted_count] = SecurityEvent.where(id: event_ids).delete_all
      result
    end

    private

    attr_reader :dry_run, :now, :limit

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
      SecurityEvent.where(severity: severity, last_seen_at: ..cutoff)
    end

    def cutoff_for(severity)
      now - retention_for(severity)
    end

    def cutoffs
      RETENTIONS.each_with_object({}) do |(severity, _retention), values|
        values[severity] = cutoff_for(severity).iso8601
      end
    end

    def retentions_in_days
      RETENTIONS.keys.index_with { |severity| retention_for(severity) / 1.day }
    end

    def retention_for(severity)
      key = RETENTION_SETTING_KEYS.fetch(severity.to_s)
      SystemSettings.limit_for(key).days
    rescue KeyError, SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      RETENTIONS.fetch(severity.to_s)
    end

    def normalize_limit(value)
      integer = value.to_i
      integer.positive? ? integer : DEFAULT_LIMIT
    end
  end
end
