module Receipts::Processing::Runs
  class RuntimeConfigSnapshot
    METADATA_KEY = "external_service_runtime_config".freeze
    ORIGIN_METADATA_KEY = "external_service_runtime_config_origin".freeze
    AI_ORIGIN_METADATA_KEY = "external_service_ai_config_origin".freeze
    RUN_CREATION_ORIGIN = "run_creation".freeze
    LEGACY_EXECUTION_CAPTURE_ORIGIN = "legacy_execution_capture".freeze

    class << self
      def fetch_or_record(run)
        new(run).fetch_or_record
      end

      def metadata_for_new_run
        snapshot = ExternalServices.runtime_config_snapshot

        {
          METADATA_KEY => snapshot.serializable_hash,
          ORIGIN_METADATA_KEY => RUN_CREATION_ORIGIN,
          AI_ORIGIN_METADATA_KEY => RUN_CREATION_ORIGIN
        }
      end
    end

    def initialize(run)
      @run = run
    end

    def fetch_or_record
      run.with_lock do
        current_metadata = run.metadata.to_h
        stored = current_metadata[METADATA_KEY]
        if current_metadata.key?(METADATA_KEY)
          snapshot = ExternalServices.deserialize_runtime_config_snapshot(stored)
          return snapshot unless snapshot.ai.model.nil?
          raise ExternalServices::RuntimeConfigUnavailableError if current_metadata.key?(AI_ORIGIN_METADATA_KEY)

          snapshot = ExternalServices.runtime_config_snapshot(legacy_snapshot: snapshot)
          metadata = current_metadata.deep_dup
          metadata[METADATA_KEY] = snapshot.serializable_hash
          metadata[AI_ORIGIN_METADATA_KEY] = LEGACY_EXECUTION_CAPTURE_ORIGIN
          run.update!(metadata: metadata)
          return snapshot
        end
        if current_metadata[ORIGIN_METADATA_KEY] == RUN_CREATION_ORIGIN || current_metadata.key?(AI_ORIGIN_METADATA_KEY)
          raise ExternalServices::RuntimeConfigUnavailableError
        end

        snapshot = ExternalServices.runtime_config_snapshot
        metadata = current_metadata.deep_dup
        metadata[METADATA_KEY] = snapshot.serializable_hash
        metadata[ORIGIN_METADATA_KEY] = LEGACY_EXECUTION_CAPTURE_ORIGIN
        metadata[AI_ORIGIN_METADATA_KEY] = LEGACY_EXECUTION_CAPTURE_ORIGIN
        run.update!(metadata: metadata)
        Rails.logger.warn("[ReceiptAnalysis] legacy_runtime_config_captured run_id=#{run.id}")
        snapshot
      end
    end

    private

    attr_reader :run
  end
end
