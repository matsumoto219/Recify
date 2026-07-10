module ReceiptAnalysisRuns
  class RuntimeConfigSnapshot
    METADATA_KEY = "external_service_runtime_config".freeze

    class << self
      def fetch_or_record(run)
        new(run).fetch_or_record
      end
    end

    def initialize(run)
      @run = run
    end

    def fetch_or_record
      run.with_lock do
        stored = run.metadata.to_h[METADATA_KEY]
        return ExternalServices.deserialize_runtime_config_snapshot(stored) if stored.present?

        snapshot = ExternalServices.runtime_config_snapshot
        metadata = run.metadata.to_h.deep_dup
        metadata[METADATA_KEY] = snapshot.serializable_hash
        run.update!(metadata: metadata)
        snapshot
      end
    end

    private

    attr_reader :run
  end
end
