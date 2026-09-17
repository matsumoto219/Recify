module Receipts::Processing::Contracts
  class AmountCalculationSnapshotLimits
    METADATA_KEY = "amount_calculation_snapshot_limits_v1".freeze
    SETTING_KEYS = {
      "max_bytes" => "limits.snapshot_amount_calculation_max_bytes",
      "computed_items" => "limits.snapshot_amount_computed_items_max",
      "evidence" => "limits.snapshot_amount_evidence_max",
      "candidates" => "amount_engine.max_candidate_snapshot_count"
    }.freeze
    RANGES = {
      "max_bytes" => 131_072..1_048_576,
      "computed_items" => 20..10_000,
      "evidence" => 40..10_000,
      "candidates" => 1..20
    }.freeze

    class << self
      def capture
        values = SystemSettings.limits_for(SETTING_KEYS.values)
        limits = SETTING_KEYS.transform_values { |key| values.fetch(key) }
        raise SystemSettings::ValidationError, "invalid_amount_snapshot_limits" unless valid?(limits)

        limits
      end

      def from_metadata(metadata)
        return unless metadata.is_a?(Hash)

        limits = metadata[METADATA_KEY]
        limits.dup if valid?(limits)
      end

      def valid?(limits)
        limits.is_a?(Hash) && limits.keys.all? { |key| key.is_a?(String) } &&
          limits.keys.sort == RANGES.keys.sort &&
          RANGES.all? { |key, range| limits[key].is_a?(Integer) && range.cover?(limits[key]) }
      end
    end
  end
end
