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
      @retention_days = ContactRequests.contact_request_retention_days
      @cutoff = @now - @retention_days.days
    end

    def call
      candidates = target_records
      records = candidates.map { |contact_request| contact_request_record(contact_request) }
      result = {
        dry_run: dry_run,
        cutoff: cutoff,
        retention_days: retention_days,
        limit: limit,
        candidate_count: records.size,
        anonymized_count: 0,
        skipped_count: 0,
        failed_count: 0,
        sample_request_uids: records.map { |record| record[:request_uid] }.first(SAMPLE_REQUEST_UID_LIMIT),
        records: records,
        errors: []
      }

      return result if dry_run

      anonymize_candidates!(candidates, result)
      result
    end

    private

    attr_reader :dry_run, :now, :limit, :retention_days, :cutoff

    def target_records
      @target_records ||= ContactRequests
        .anonymizable_scope(now: now)
        .order(Arel.sql("COALESCE(handled_at, updated_at) ASC"), :id)
        .limit(limit)
        .to_a
    end

    def anonymize_candidates!(candidates, result)
      candidates.each do |contact_request|
        outcome = ContactRequest.transaction(requires_new: true) do
          current = ContactRequest.lock.find_by(id: contact_request.id)
          next :skipped unless current && anonymizable_now?(current)

          ContactRequests.anonymize(current)
          :anonymized
        end

        result[outcome == :anonymized ? :anonymized_count : :skipped_count] += 1
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << anonymize_error_record(contact_request, e)
      end
    end

    def anonymizable_now?(contact_request)
      return false unless RetentionPolicy::TERMINAL_STATUSES.include?(contact_request.status)
      return false if ContactRequests.anonymized?(contact_request)

      timestamp = contact_request.handled_at || contact_request.updated_at
      timestamp.present? && timestamp <= cutoff
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
