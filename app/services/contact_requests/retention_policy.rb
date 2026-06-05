module ContactRequests
  module RetentionPolicy
    CONTACT_REQUEST_RETENTION_DAYS = 180
    TERMINAL_STATUSES = %w[resolved closed].freeze

    class << self
      def retention_scope
        ContactRequest.where(status: TERMINAL_STATUSES)
      end

      def anonymizable_scope(now: Time.current)
        cutoff = retention_cutoff(now: now)

        retention_scope.where(
          <<~SQL.squish,
            (handled_at IS NOT NULL AND handled_at <= :cutoff)
            OR (handled_at IS NULL AND updated_at <= :cutoff)
          SQL
          cutoff: cutoff
        )
      end

      def retention_cutoff(now: Time.current)
        now - CONTACT_REQUEST_RETENTION_DAYS.days
      end
    end
  end
end
