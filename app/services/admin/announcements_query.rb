module Admin
  class AnnouncementsQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end

      def filter_options
        {
          statuses: Announcement::STATUSES,
          kinds: Announcement::KINDS,
          pinned: %w[true false]
        }
      end
    end

    def initialize(
      status: nil,
      kind: nil,
      pinned: nil,
      public_id: nil,
      title: nil,
      starts_at_from: nil,
      starts_at_to: nil,
      ends_at_from: nil,
      ends_at_to: nil,
      published_at_from: nil,
      published_at_to: nil,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @status = status
      @kind = kind
      @pinned = pinned
      @public_id = public_id
      @title = title
      @starts_at_from = starts_at_from
      @starts_at_to = starts_at_to
      @ends_at_from = ends_at_from
      @ends_at_to = ends_at_to
      @published_at_from = published_at_from
      @published_at_to = published_at_to
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      announcements = relation
        .includes(:created_by, :updated_by, :announcement_links)
        .ordered_for_admin
        .limit(@limit)
        .offset(@offset)
        .to_a

      Result.new(
        records: announcements.map { |announcement| build_record(announcement) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = Announcement.all
      relation = filter_by_column(relation, :status, @status, Announcement::STATUSES)
      relation = filter_by_column(relation, :kind, @kind, Announcement::KINDS)
      relation = filter_by_pinned(relation)
      relation = filter_by_public_id(relation)
      relation = filter_by_title(relation)
      relation = filter_by_time_range(relation, :starts_at, @starts_at_from, @starts_at_to)
      relation = filter_by_time_range(relation, :ends_at, @ends_at_from, @ends_at_to)
      filter_by_time_range(relation, :published_at, @published_at_from, @published_at_to)
    end

    def filter_by_column(relation, column, value, allowlist)
      values = filter_values(value).select { |item| allowlist.include?(item) }
      return relation if values.blank?

      relation.where(column => values)
    end

    def filter_by_pinned(relation)
      return relation unless boolean_filter?(@pinned)

      relation.where(pinned: boolean_value(@pinned))
    end

    def filter_by_public_id(relation)
      public_id = @public_id.to_s.strip
      return relation if public_id.blank?

      relation.where(public_id: public_id)
    end

    def filter_by_title(relation)
      title = @title.to_s.strip
      return relation if title.blank?

      escaped = ActiveRecord::Base.sanitize_sql_like(title)
      relation.where("announcements.title LIKE ?", "%#{escaped}%")
    end

    def filter_by_time_range(relation, column, from_value, to_value)
      from_time = parse_time(from_value)
      to_time = parse_time(to_value)
      relation = relation.where(column => from_time..) if from_time
      relation = relation.where(column => ..to_time) if to_time
      relation
    end

    def build_record(announcement)
      {
        announcement: announcement,
        id: announcement.id,
        public_id: announcement.public_id,
        title: announcement.title,
        status: announcement.status,
        kind: announcement.kind,
        pinned: announcement.pinned?,
        priority: announcement.priority,
        published_at: announcement.published_at,
        starts_at: announcement.starts_at,
        ends_at: announcement.ends_at,
        links_count: announcement.announcement_links.size,
        created_by_email: announcement.created_by&.email,
        updated_by_email: announcement.updated_by&.email,
        created_at: announcement.created_at,
        updated_at: announcement.updated_at
      }
    end

    def filter_values(value)
      Array(value).filter_map { |item| item.to_s.strip.presence }
    end

    def boolean_filter?(value)
      %w[true false].include?(value.to_s)
    end

    def boolean_value(value)
      value.to_s == "true"
    end

    def normalize_limit(value)
      normalized = value.to_i
      normalized = DEFAULT_LIMIT if normalized <= 0

      [ normalized, MAX_LIMIT ].min
    end

    def normalize_offset(value)
      [ value.to_i, 0 ].max
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
