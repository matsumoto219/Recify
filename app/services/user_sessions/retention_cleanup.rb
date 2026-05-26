module UserSessions
  class RetentionCleanup
    DEFAULT_LIMIT = 1000
    SAMPLE_SESSION_ID_LIMIT = 20
    ACTIVE_LAST_SEEN_PERIOD = 30.days

    class << self
      def call(dry_run: true, cutoff: 90.days.ago, limit: DEFAULT_LIMIT)
        new(dry_run: dry_run, cutoff: cutoff, limit: limit).call
      end
    end

    def initialize(dry_run:, cutoff:, limit:)
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
      @cutoff = cutoff || 90.days.ago
      @limit = normalize_limit(limit)
    end

    def call
      sessions = target_sessions
      records = sessions.map { |session| session_record(session) }
      result = {
        dry_run: dry_run,
        cutoff: cutoff,
        limit: limit,
        expired_count: sessions.size,
        deleted_count: 0,
        sample_session_ids: records.map { |record| record[:id] }.first(SAMPLE_SESSION_ID_LIMIT),
        errors: []
      }

      return result if dry_run

      result[:deleted_count] = UserSession.where(id: records.map { |record| record[:id] }).delete_all
      result
    end

    private

    attr_reader :dry_run, :cutoff, :limit

    def target_sessions
      expired_scope
        .order(Arel.sql("COALESCE(signed_out_at, revoked_at, expired_at, last_seen_at) ASC"), :id)
        .limit(limit)
        .to_a
    end

    def expired_scope
      active_cutoff = ACTIVE_LAST_SEEN_PERIOD.ago

      UserSession
        .joins(:user)
        .where(
          <<~SQL.squish,
            user_sessions.signed_out_at <= :cutoff
            OR user_sessions.revoked_at <= :cutoff
            OR user_sessions.expired_at <= :cutoff
            OR (
              user_sessions.signed_out_at IS NULL
              AND user_sessions.revoked_at IS NULL
              AND user_sessions.expired_at IS NULL
              AND user_sessions.last_seen_at <= :cutoff
              AND NOT (
                user_sessions.last_seen_at >= :active_cutoff
                AND user_sessions.session_version = users.session_version
              )
            )
          SQL
          cutoff: cutoff,
          active_cutoff: active_cutoff
        )
    end

    def session_record(session)
      {
        id: session.id,
        session_version: session.session_version,
        signed_out_at: session.signed_out_at,
        revoked_at: session.revoked_at,
        expired_at: session.expired_at,
        last_seen_at: session.last_seen_at
      }
    end

    def normalize_limit(value)
      integer = value.to_i
      integer.positive? ? integer : DEFAULT_LIMIT
    end
  end
end
