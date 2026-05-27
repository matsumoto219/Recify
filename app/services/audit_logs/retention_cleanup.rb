module AuditLogs
  class RetentionCleanup
    DEFAULT_LIMIT = 1000
    SAMPLE_AUDIT_ID_LIMIT = 20

    class << self
      def call(dry_run: true, categories: nil, now: Time.current, limit: DEFAULT_LIMIT)
        new(
          dry_run: dry_run,
          categories: categories,
          now: now,
          limit: limit
        ).call
      end
    end

    def initialize(dry_run:, categories:, now:, limit:)
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
      @categories = normalize_categories(categories)
      @now = now || Time.current
      @limit = normalize_limit(limit)
    end

    def call
      records = target_records
      audit_ids = records.map(&:id)

      result = {
        dry_run: dry_run,
        expired_count: audit_ids.size,
        deleted_count: 0,
        sample_audit_ids: audit_ids.first(SAMPLE_AUDIT_ID_LIMIT),
        categories: categories.map(&:to_s),
        cutoffs: cutoffs,
        errors: []
      }

      return result if dry_run

      result[:deleted_count] = AuditLog.where(id: audit_ids).delete_all
      result
    end

    private

    attr_reader :dry_run, :categories, :now, :limit

    def target_records
      remaining = limit
      records = []

      categories.each do |category|
        break if remaining <= 0

        relation = relation_for(category)
        next if relation.blank?

        category_records = relation
          .order(created_at: :asc, id: :asc)
          .limit(remaining)
          .to_a
        records.concat(category_records)
        remaining -= category_records.size
      end

      records
    end

    def relation_for(category)
      cutoff = cutoff_for(category)
      return if cutoff.blank?

      relation = AuditLog.where(created_at: ..cutoff)

      case category
      when :high_risk_admin
        relation.where(action: RetentionPolicy.actions_for(category))
      when :cleanup_execute
        relation.where(action: RetentionPolicy.actions_for(category)).where.not(outcome: "failed")
      when :cleanup_failed
        relation.where(action: RetentionPolicy.actions_for(category), outcome: "failed")
      when :passkey_reauth
        relation.where(action: RetentionPolicy.actions_for(category))
      when :system_dry_run
        relation.where(action: RetentionPolicy.actions_for(category)).where.not(outcome: "failed")
      when :routine_system
        AuditLog.none
      else
        AuditLog.none
      end
    end

    def cutoffs
      categories.each_with_object({}) do |category, values|
        cutoff = cutoff_for(category)
        values[category.to_s] = cutoff.iso8601 if cutoff.respond_to?(:iso8601)
      end
    end

    def cutoff_for(category)
      RetentionPolicy.cutoff_for(category, now: now)
    end

    def normalize_categories(value)
      selected = Array(value).flat_map { |entry| entry.to_s.split(",") }
      selected = RetentionPolicy.cleanup_categories if selected.blank?

      selected.filter_map do |category|
        normalized = category.to_s.strip
        next if normalized.blank?

        key = normalized.to_sym
        next unless RetentionPolicy.cleanup_categories.include?(key)

        key
      end.uniq
    end

    def normalize_limit(value)
      integer = value.to_i
      integer.positive? ? integer : DEFAULT_LIMIT
    end
  end
end
