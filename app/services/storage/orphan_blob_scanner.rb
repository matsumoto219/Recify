module Storage
  class OrphanBlobScanner
    DEFAULT_OLDER_THAN = 48.hours
    RETENTION_HOURS_KEY = "retention.orphan_blobs_hours"
    DEFAULT_SAMPLE_LIMIT = 10

    class << self
      def call(created_before: nil, older_than: nil, limit: nil, sample_limit: DEFAULT_SAMPLE_LIMIT)
        new(
          created_before: created_before,
          older_than: older_than,
          limit: limit,
          sample_limit: sample_limit
        ).call
      end

      def retention_duration
        retention_hours.hours
      end

      def retention_hours
        SystemSettings.limit_for(RETENTION_HOURS_KEY)
      rescue StandardError
        DEFAULT_OLDER_THAN.in_hours.to_i
      end
    end

    def initialize(created_before: nil, older_than: nil, limit: nil, sample_limit: DEFAULT_SAMPLE_LIMIT)
      @created_before = created_before
      @older_than = older_than
      @limit = normalize_limit(limit)
      @sample_limit = normalize_limit(sample_limit) || DEFAULT_SAMPLE_LIMIT
    end

    def call
      blobs = candidate_blobs.to_a

      {
        count: blobs.size,
        bytes: blobs.sum(&:byte_size),
        blob_ids: blobs.map(&:id),
        sample: blobs.first(sample_limit).map { |blob| sample_blob(blob) },
        created_before: threshold.iso8601,
        older_than_seconds: older_than_seconds
      }
    end

    private

    attr_reader :created_before, :older_than, :limit, :sample_limit

    def candidate_blobs
      scope = ActiveStorage::Blob.unattached
        .where("active_storage_blobs.created_at < ?", threshold)
        .order(:created_at, :id)

      limit.present? ? scope.limit(limit) : scope
    end

    def sample_blob(blob)
      {
        id: blob.id,
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        created_at: blob.created_at&.iso8601
      }
    end

    def threshold
      @threshold ||= begin
        time = created_before.presence
        time.present? ? Time.zone.parse(time.to_s) : Time.current - older_than_duration
      end
    rescue ArgumentError, TypeError
      Time.current - DEFAULT_OLDER_THAN
    end

    def older_than_duration
      return older_than if older_than.respond_to?(:ago)
      return older_than.seconds if older_than.is_a?(Numeric)

      self.class.retention_duration
    end

    def older_than_seconds
      return nil if created_before.present?

      older_than_duration.to_i
    end

    def normalize_limit(value)
      integer = value.to_i

      integer.positive? ? integer : nil
    end
  end
end
