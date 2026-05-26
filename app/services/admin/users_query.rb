module Admin
  class UsersQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end

      def find(id:)
        new(id: id, limit: 1).call.records.first
      end
    end

    def initialize(
      id: nil,
      email: nil,
      admin: nil,
      guest: nil,
      confirmed: nil,
      locked: nil,
      has_passkey: nil,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @id = id
      @email = email
      @admin = admin
      @guest = guest
      @confirmed = confirmed
      @locked = locked
      @has_passkey = has_passkey
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      users = relation.order(created_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a
      aggregates = aggregates_for(users)

      Result.new(
        records: users.map { |user| build_record(user, aggregates) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = User.all
      relation = filter_by_id(relation)
      relation = filter_by_email(relation)
      relation = filter_by_boolean_column(relation, :admin, @admin)
      relation = filter_by_boolean_column(relation, :guest, @guest)
      relation = filter_by_presence(relation, :confirmed_at, @confirmed)
      relation = filter_by_presence(relation, :locked_at, @locked)
      filter_by_passkey_presence(relation)
    end

    def filter_by_id(relation)
      user_id = positive_integer(@id)
      return relation if user_id.blank?

      relation.where(id: user_id)
    end

    def filter_by_email(relation)
      email = @email.to_s.strip.downcase
      return relation if email.blank?

      escaped = ActiveRecord::Base.sanitize_sql_like(email)
      relation.where("LOWER(users.email) LIKE ?", "%#{escaped}%")
    end

    def filter_by_boolean_column(relation, column, value)
      return relation unless boolean_filter?(value)

      relation.where(column => boolean_value(value))
    end

    def filter_by_presence(relation, column, value)
      return relation unless boolean_filter?(value)

      boolean_value(value) ? relation.where.not(column => nil) : relation.where(column => nil)
    end

    def filter_by_passkey_presence(relation)
      return relation unless boolean_filter?(@has_passkey)

      subquery = Passkey.select(:user_id)
      boolean_value(@has_passkey) ? relation.where(id: subquery) : relation.where.not(id: subquery)
    end

    def aggregates_for(users)
      user_ids = users.map(&:id)

      {
        passkeys_count: Passkey.where(user_id: user_ids).group(:user_id).count,
        receipts_count: Receipt.where(user_id: user_ids).group(:user_id).count,
        latest_passkey_last_used_at: Passkey.where(user_id: user_ids).group(:user_id).maximum(:last_used_at)
      }
    end

    def build_record(user, aggregates)
      record = {
        id: user.id,
        email: user.email,
        name: user.name,
        admin: user.admin?,
        guest: user.guest?,
        confirmed: user.confirmed?,
        locked: user.locked_at.present?,
        security: {
          confirmed_at: user.confirmed_at,
          unconfirmed_email_present: user.unconfirmed_email.present?,
          failed_attempts: user.failed_attempts,
          unlock_sent_at: unlock_sent_at_for(user),
          locked_at: user.locked_at
        },
        sign_in: {
          sign_in_count: user.sign_in_count,
          current_sign_in_at: user.current_sign_in_at,
          last_sign_in_at: user.last_sign_in_at,
          current_sign_in_ip: user.current_sign_in_ip&.to_s,
          last_sign_in_ip: user.last_sign_in_ip&.to_s
        },
        passkeys_count: aggregates[:passkeys_count].fetch(user.id, 0),
        latest_passkey_last_used_at: aggregates[:latest_passkey_last_used_at][user.id],
        receipts_count: aggregates[:receipts_count].fetch(user.id, 0),
        timestamps: {
          created_at: user.created_at,
          updated_at: user.updated_at
        }
      }
      record[:active_sessions] = active_session_summary_for(user) if include_session_summary?
      record
    end

    def include_session_summary?
      @id.present?
    end

    def active_session_summary_for(user)
      summary = UserSessions.summary_for(user: user)
      {
        count: summary.active_sessions_count,
        latest_seen_at: summary.latest_seen_at,
        latest_sign_in_method: summary.latest_sign_in_method,
        latest_ip: summary.latest_ip,
        latest_user_agent: summary.latest_user_agent,
        recent: summary.recent_sessions.map { |session| active_session_record(session) }
      }
    end

    def active_session_record(session)
      {
        session_version: session.session_version,
        started_at: session.started_at,
        last_seen_at: session.last_seen_at,
        sign_in_method: session.sign_in_method,
        ip_address: session.ip_address&.to_s,
        user_agent: session.user_agent
      }
    end

    def boolean_filter?(value)
      !value.nil? && value.to_s.strip.present?
    end

    def boolean_value(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def normalize_limit(value)
      normalized = value.to_i
      normalized = DEFAULT_LIMIT if normalized <= 0

      [ normalized, MAX_LIMIT ].min
    end

    def normalize_offset(value)
      [ value.to_i, 0 ].max
    end

    def positive_integer(value)
      integer = value.to_i
      integer.positive? ? integer : nil
    end

    def unlock_sent_at_for(user)
      user.unlock_sent_at if user.respond_to?(:unlock_sent_at)
    end
  end
end
