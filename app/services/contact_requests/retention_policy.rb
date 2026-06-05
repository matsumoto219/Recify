module ContactRequests
  module RetentionPolicy
    DEFAULT_CONTACT_REQUEST_RETENTION_DAYS = 180
    CONTACT_REQUEST_RETENTION_DAYS = DEFAULT_CONTACT_REQUEST_RETENTION_DAYS
    TERMINAL_STATUSES = %w[resolved closed].freeze

    class << self
      def retention_days
        SystemSettings.limit_for("retention.contact_requests_days")
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        DEFAULT_CONTACT_REQUEST_RETENTION_DAYS
      end

      def retention_scope
        ContactRequest.where(status: TERMINAL_STATUSES)
      end

      def anonymizable_scope(now: Time.current)
        cutoff = retention_cutoff(now: now)

        retention_scope
          .where.not(body: Anonymizer::REDACTED_BODY)
          .where(
          <<~SQL.squish,
            (handled_at IS NOT NULL AND handled_at <= :cutoff)
            OR (handled_at IS NULL AND updated_at <= :cutoff)
          SQL
          cutoff: cutoff
        )
      end

      def retention_cutoff(now: Time.current)
        now - retention_days.days
      end
    end
  end
end
