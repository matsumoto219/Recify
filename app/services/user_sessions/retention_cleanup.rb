module UserSessions
  class RetentionCleanup
    DEFAULT_LIMIT = 1000
    SAMPLE_SESSION_ID_LIMIT = 20
    ACTIVE_LAST_SEEN_PERIOD = 30.days

    class << self
      def call(dry_run: true, cutoff: nil, limit: DEFAULT_LIMIT)
        new(dry_run: dry_run, cutoff: cutoff, limit: limit).call
      end
    end

    def initialize(dry_run:, cutoff:, limit:)
      @dry_run = normalize_boolean(dry_run)
      @cutoff = cutoff || UserSessions.retention_cutoff
      @limit = normalize_limit(limit)
      @active_cutoff = Time.current - ACTIVE_LAST_SEEN_PERIOD
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
        skipped_count: 0,
        failed_count: 0,
        sample_session_ids: records.map { |record| record[:id] }.first(SAMPLE_SESSION_ID_LIMIT),
        errors: []
      }

      return result if dry_run

      delete_candidates!(sessions, result)
      result
    end

    private

    attr_reader :dry_run, :cutoff, :limit, :active_cutoff

    def target_sessions
      expired_scope
        .order(Arel.sql("COALESCE(signed_out_at, revoked_at, expired_at, last_seen_at) ASC"), :id)
        .limit(limit)
        .to_a
    end

    def expired_scope
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

    def delete_candidates!(candidates, result)
      candidates.each do |candidate|
        outcome = UserSession.transaction(requires_new: true) do
          user_session = UserSession.lock.find_by(id: candidate.id)
          next :skipped unless user_session && expired_now?(user_session)

          user_session.delete
          :deleted
        end

        result[outcome == :deleted ? :deleted_count : :skipped_count] += 1
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << { session_id: candidate&.id, error_class: e.class.name }
      end
    end

    def expired_now?(user_session)
      return true if terminal_timestamp_expired?(user_session)
      return false if terminal_timestamp_present?(user_session)
      return false unless user_session.last_seen_at <= cutoff

      !active_current_session?(user_session)
    end

    def terminal_timestamp_expired?(user_session)
      terminal_timestamps(user_session).compact.any? { |timestamp| timestamp <= cutoff }
    end

    def terminal_timestamp_present?(user_session)
      terminal_timestamps(user_session).compact.any?
    end

    def terminal_timestamps(user_session)
      [ user_session.signed_out_at, user_session.revoked_at, user_session.expired_at ]
    end

    def active_current_session?(user_session)
      current_version = User.where(id: user_session.user_id).pick(:session_version)
      user_session.last_seen_at >= active_cutoff && user_session.session_version == current_version
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

    def normalize_boolean(value)
      return true if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
