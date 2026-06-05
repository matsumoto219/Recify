require "openssl"

module UserSessions
  USER_SESSION_UID_SESSION_KEY = :user_session_uid
  DIGEST_SALT = "recify/user-session-uid-digest"
  MAX_USER_AGENT_BYTES = 500
  TOUCH_INTERVAL = 5.minutes
  DEFAULT_RETENTION_DAYS = 90
  RETENTION_PERIOD = DEFAULT_RETENTION_DAYS.days

  Summary = Struct.new(
    :active_sessions_count,
    :latest_seen_at,
    :latest_sign_in_method,
    :latest_ip,
    :latest_user_agent,
    :recent_sessions,
    keyword_init: true
  )

  class << self
    def cleanup_retention(dry_run: true, cutoff: nil, limit: 1000)
      RetentionCleanup.call(
        dry_run: dry_run,
        cutoff: cutoff,
        limit: limit
      )
    end

    def retention_cutoff(now: Time.current)
      now - retention_days.days
    end

    def retention_days
      SystemSettings.limit_for("retention.user_sessions_days")
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_RETENTION_DAYS
    end

    def record_sign_in(user:, request:, session:, method:)
      return unless user && session

      raw_uid = SecureRandom.uuid
      session[USER_SESSION_UID_SESSION_KEY] = raw_uid
      now = Time.current

      UserSession.create!(
        user: user,
        session_uid_digest: digest(raw_uid),
        session_version: session_version_for(user),
        started_at: now,
        last_seen_at: now,
        ip_address: request&.remote_ip,
        user_agent: truncate_user_agent(request&.user_agent),
        sign_in_method: method.to_s
      )
    rescue StandardError => e
      Rails.logger.warn("[UserSessions] record_sign_in failed: #{e.class.name}")
      nil
    end

    def touch_current(user:, request:, session:)
      return unless user && session

      record = current_record_for(user: user, session: session)
      return unless record
      return record unless record.last_seen_at < TOUCH_INTERVAL.ago

      record.update!(
        last_seen_at: Time.current,
        ip_address: request&.remote_ip,
        user_agent: truncate_user_agent(request&.user_agent)
      )
      record
    rescue StandardError => e
      Rails.logger.warn("[UserSessions] touch_current failed: #{e.class.name}")
      nil
    end

    def record_sign_out(user:, session:)
      return unless session

      record = current_record_for(user: user, session: session)
      session.delete(USER_SESSION_UID_SESSION_KEY)
      return unless record

      record.update!(signed_out_at: Time.current) if record.signed_out_at.blank?
      record
    rescue StandardError => e
      Rails.logger.warn("[UserSessions] record_sign_out failed: #{e.class.name}")
      nil
    end

    def mark_revoked_for_user(user:)
      return 0 unless user

      now = Time.current
      UserSession
        .where(user: user, signed_out_at: nil, revoked_at: nil)
        .update_all(revoked_at: now, updated_at: now)
    rescue StandardError => e
      Rails.logger.warn("[UserSessions] mark_revoked_for_user failed: #{e.class.name}")
      0
    end

    def active_for(user:)
      return UserSession.none unless user

      UserSession.active
                 .where(user: user, session_version: session_version_for(user))
                 .order(last_seen_at: :desc, id: :desc)
    end

    def summary_for(user:)
      sessions = active_for(user: user).limit(5).to_a
      latest = sessions.first

      Summary.new(
        active_sessions_count: active_for(user: user).count,
        latest_seen_at: latest&.last_seen_at,
        latest_sign_in_method: latest&.sign_in_method,
        latest_ip: latest&.ip_address&.to_s,
        latest_user_agent: latest&.user_agent,
        recent_sessions: sessions
      )
    end

    private

    def current_record_for(user:, session:)
      raw_uid = session[USER_SESSION_UID_SESSION_KEY].to_s
      return if raw_uid.blank?

      UserSession.find_by(
        user: user,
        session_uid_digest: digest(raw_uid)
      )
    end

    def digest(raw_uid)
      OpenSSL::HMAC.hexdigest("SHA256", digest_key, raw_uid.to_s)
    end

    def digest_key
      Rails.application.key_generator.generate_key(DIGEST_SALT, 32)
    end

    def truncate_user_agent(value)
      value = value.to_s
      return if value.blank?
      return value if value.bytesize <= MAX_USER_AGENT_BYTES

      value.byteslice(0, MAX_USER_AGENT_BYTES).scrub
    end

    def session_version_for(user)
      user.respond_to?(:session_version) ? user.session_version.to_i : 0
    end
  end
end
