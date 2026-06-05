module ContactRequests
  class RetentionCleanup
    DEFAULT_LIMIT = 1000
    SAMPLE_REQUEST_UID_LIMIT = 5

    class << self
      def call(dry_run: true, now: Time.current, limit: DEFAULT_LIMIT)
        new(dry_run: dry_run, now: now, limit: limit).call
      end
    end

    def initialize(dry_run:, now:, limit:)
      @dry_run = normalize_boolean(dry_run)
      @now = now || Time.current
      @limit = normalize_limit(limit)
    end

    def call
      records = target_records.map { |contact_request| contact_request_record(contact_request) }
      result = {
        dry_run: dry_run,
        cutoff: ContactRequests.retention_cutoff(now: now),
        retention_days: ContactRequests.contact_request_retention_days,
        limit: limit,
        candidate_count: records.size,
        anonymized_count: 0,
        failed_count: 0,
        sample_request_uids: records.map { |record| record[:request_uid] }.first(SAMPLE_REQUEST_UID_LIMIT),
        records: records,
        errors: []
      }

      return result if dry_run

      anonymize_candidates!(result)
      result
    end

    private

    attr_reader :dry_run, :now, :limit

    def target_records
      @target_records ||= ContactRequests
        .anonymizable_scope(now: now)
        .order(Arel.sql("COALESCE(handled_at, updated_at) ASC"), :id)
        .limit(limit)
        .to_a
    end

    def anonymize_candidates!(result)
      target_records.each do |contact_request|
        ContactRequests.anonymize(contact_request)
        result[:anonymized_count] += 1
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << anonymize_error_record(contact_request, e)
      end
    end

    def contact_request_record(contact_request)
      {
        id: contact_request.id,
        request_uid: contact_request.request_uid,
        status: contact_request.status,
        category: contact_request.category,
        source: contact_request.source,
        handled_at: contact_request.handled_at,
        updated_at: contact_request.updated_at
      }
    end

    def anonymize_error_record(contact_request, error)
      {
        request_uid: contact_request&.request_uid,
        error_class: error.class.name
      }
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
