class ReceiptAnalysisPipeline
  FinalizeDecision = Struct.new(
    :finalize_strategy,
    :error_code,
    :error_message,
    :receipt_attributes,
    :ocr_result,
    :ai_result,
    :metadata,
    keyword_init: true
  ) do
    SCHEMA_VERSION = ReceiptAnalysisRuns::SnapshotBuilder::FINALIZE_DECISION_SCHEMA_VERSION
    STRATEGIES = ReceiptAnalysisRuns::SnapshotBuilder::FINALIZE_STRATEGIES

    def self.from_snapshot(snapshot)
      attributes = normalized_snapshot(snapshot)
      return nil if attributes.blank?
      return nil unless attributes[:schema_version].to_s == SCHEMA_VERSION
      return nil unless STRATEGIES.include?(attributes[:strategy].to_s)

      new(
        finalize_strategy: attributes[:strategy].to_s,
        error_code: attributes[:error_code].presence,
        error_message: attributes[:error_message].presence,
        receipt_attributes: normalized_hash(attributes[:receipt_attributes]).to_h,
        ocr_result: nil,
        ai_result: nil,
        metadata: normalized_hash(attributes[:metadata]).to_h
      )
    end

    def strategy
      finalize_strategy
    end

    def self.normalized_snapshot(snapshot)
      return snapshot.with_indifferent_access if snapshot.respond_to?(:with_indifferent_access)

      {}.with_indifferent_access
    end
    private_class_method :normalized_snapshot

    def self.normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

      {}.with_indifferent_access
    end
    private_class_method :normalized_hash
  end
end
