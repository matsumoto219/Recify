module Admin
  class ReceiptAnalysisCleanupPreview
    DEFAULT_STALE_LIMIT = 100
    MAX_STALE_LIMIT = 100
    DEFAULT_RETENTION_LIMIT = 1000
    MAX_RETENTION_LIMIT = 1000

    Result = Struct.new(:stale, :retention, :params, keyword_init: true)

    class << self
      def call(**params)
        new(**params).call
      end
    end

    def initialize(
      stale_cutoff: nil,
      stale_limit: DEFAULT_STALE_LIMIT,
      retention_cutoff: nil,
      retention_limit: DEFAULT_RETENTION_LIMIT,
      **_ignored
    )
      @stale_cutoff = normalize_time(stale_cutoff, 6.hours.ago)
      @stale_limit = normalize_limit(
        stale_limit,
        default: DEFAULT_STALE_LIMIT,
        max: MAX_STALE_LIMIT,
        field: :stale_limit
      )
      @retention_cutoff = normalize_time(retention_cutoff, Time.current)
      @retention_limit = normalize_limit(
        retention_limit,
        default: DEFAULT_RETENTION_LIMIT,
        max: MAX_RETENTION_LIMIT,
        field: :retention_limit
      )
    end

    def call
      Result.new(
        stale: stale_preview,
        retention: retention_preview,
        params: {
          stale_cutoff: stale_cutoff,
          stale_limit: stale_limit,
          retention_cutoff: retention_cutoff,
          retention_limit: retention_limit
        }
      )
    end

    private

    attr_reader :stale_cutoff, :stale_limit, :retention_cutoff, :retention_limit

    def stale_preview
      Receipts::Processing.cleanup_stale(
        cutoff: stale_cutoff,
        limit: stale_limit,
        dry_run: true
      )
    end

    def retention_preview
      Receipts::Processing.cleanup_expired(
        cutoff: retention_cutoff,
        limit: retention_limit,
        dry_run: true
      )
    end

    def normalize_limit(value, default:, max:, field:)
      normalized = UserNumericInput.integer(value)
      normalized = default if normalized <= 0

      [ normalized, max ].min
    rescue UserNumericInput::InvalidValue
      raise Admin::ReceiptAnalysisCleanupInvalidParameter, "#{field}_invalid"
    end

    def normalize_time(value, fallback)
      return fallback if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return value.to_time.in_time_zone if value.is_a?(Date) || value.is_a?(DateTime)

      Time.zone.parse(value.to_s) || fallback
    rescue ArgumentError, TypeError
      fallback
    end
  end
end
