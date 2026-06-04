module Admin
  class ContactRequestsQuery
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

      def filter_options
        {
          statuses: ContactRequest::STATUSES,
          categories: ContactRequest::CATEGORIES,
          sources: ContactRequest::SOURCES
        }
      end
    end

    def initialize(
      id: nil,
      status: nil,
      category: nil,
      source: nil,
      email_digest: nil,
      user_id: nil,
      request_uid: nil,
      created_from: nil,
      created_to: nil,
      limit: DEFAULT_LIMIT,
      offset: 0
    )
      @id = id
      @status = status
      @category = category
      @source = source
      @email_digest = email_digest
      @user_id = user_id
      @request_uid = request_uid
      @created_from = created_from
      @created_to = created_to
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      records = relation.order(created_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a

      Result.new(
        records: records.map { |contact_request| build_record(contact_request) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = ContactRequest.includes(:user, :handled_by_user)
      relation = filter_by_id(relation)
      relation = filter_by_column(relation, :status, @status, ContactRequest::STATUSES)
      relation = filter_by_column(relation, :category, @category, ContactRequest::CATEGORIES)
      relation = filter_by_column(relation, :source, @source, ContactRequest::SOURCES)
      relation = filter_by_exact(relation, :email_digest, @email_digest)
      relation = filter_by_user_id(relation)
      relation = filter_by_exact(relation, :request_uid, @request_uid)
      filter_by_created_at(relation)
    end

    def filter_by_id(relation)
      id = positive_integer(@id)
      return relation if id.blank?

      relation.where(id: id)
    end

    def filter_by_column(relation, column, value, allowlist)
      values = filter_values(value).select { |item| allowlist.include?(item) }
      return relation if values.blank?

      relation.where(column => values)
    end

    def filter_by_exact(relation, column, value)
      normalized = value.to_s.strip
      return relation if normalized.blank?

      relation.where(column => normalized)
    end

    def filter_by_user_id(relation)
      user_id = positive_integer(@user_id)
      return relation if user_id.blank?

      relation.where(user_id: user_id)
    end

    def filter_by_created_at(relation)
      created_from = parse_time(@created_from)
      created_to = parse_time(@created_to)
      relation = relation.where(created_at: created_from..) if created_from
      relation = relation.where(created_at: ..created_to) if created_to
      relation
    end

    def build_record(contact_request)
      {
        contact_request: contact_request,
        id: contact_request.id,
        request_uid: contact_request.request_uid,
        status: contact_request.status,
        category: contact_request.category,
        source: contact_request.source,
        sender_name: contact_request.sender_name,
        subject: contact_request.subject,
        body: contact_request.body,
        user_id: contact_request.user_id,
        user_email: contact_request.user&.email,
        email_masked: masked_email(contact_request.email),
        email_digest: contact_request.email_digest,
        ip_address: contact_request.ip_address&.to_s,
        user_agent: contact_request.user_agent,
        request_id: contact_request.request_id,
        handled_by_user_id: contact_request.handled_by_user_id,
        handled_by_email: contact_request.handled_by_user&.email,
        handled_at: contact_request.handled_at,
        created_at: contact_request.created_at,
        updated_at: contact_request.updated_at
      }
    end

    def masked_email(email)
      local, domain = email.to_s.split("@", 2)
      return "-" if local.blank? || domain.blank?

      "#{local.first(2)}***@#{domain}"
    end

    def filter_values(value)
      Array(value).filter_map { |item| item.to_s.strip.presence }
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

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
