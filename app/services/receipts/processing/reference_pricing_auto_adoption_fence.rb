class Receipts::Processing::ReferencePricingAutoAdoptionFence
  CLAIM_METADATA_KEY = "reference_pricing_auto_adoption_claim"
  CLAIM_SCHEMA_VERSION = "reference_pricing_auto_adoption_claim_v1"
  CLAIM_KEYS = %w[schema_version proposal_checksum].freeze
  SUPPORTED_RUN_SOURCES =
    Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::SUPPORTED_RUN_SOURCES
  REASONS = %w[
    enabled
    run_missing
    run_source_unsupported
    gate_snapshot_invalid
    start_gate_disabled
    current_setting_disabled
    setting_generation_mismatch
    proposal_binding_mismatch
    already_claimed
    claim_invalid
    operation_not_committed
  ].freeze

  Result = Data.define(:enabled, :reason, :candidate_identity, :destination_identity) do
    def initialize(enabled:, reason:, candidate_identity: nil, destination_identity: nil)
      super(
        enabled: enabled == true,
        reason: reason.to_s.dup.freeze,
        candidate_identity: candidate_identity&.dup&.freeze,
        destination_identity: destination_identity&.dup&.freeze
      )
    end

    def enabled?
      enabled == true
    end
  end

  SerializationResult = Data.define(:gate_result, :operation_committed) do
    def operation_committed?
      operation_committed == true
    end
  end

  class << self
    def with_locked_run(run:)
      serialized = with_serialized_run(run:) do |locked_run, gate_result|
        next false unless gate_result.enabled?

        yield locked_run
      end
      result = serialized.gate_result
      if result&.enabled? && !serialized.operation_committed?
        return result(
          "operation_not_committed",
          candidate_identity: result.candidate_identity,
          destination_identity: result.destination_identity
        )
      end

      result
    end

    def serialization_required?(run)
      return false unless SUPPORTED_RUN_SOURCES.include?(run&.source)

      gate = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot.from_snapshot(
        run&.metadata.to_h[
          Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::METADATA_KEY
        ],
        run:,
        require_binding: true
      )

      gate.present? && gate["setting_enabled"] == true
    rescue ArgumentError, KeyError, TypeError
      false
    end

    def with_serialized_run(run:)
      gate_result = nil
      operation_committed = false
      SystemSettings.with_dependency_lock(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY) do
        ReceiptAnalysisRun.transaction(requires_new: true) do
          current_entry = SystemSettings.fetch_for_update(
            SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY
          )
          locked_run = ReceiptAnalysisRun.lock.find_by(id: run&.id)
          gate_result = evaluate(locked_run, current_entry:)
          completed = yield locked_run, gate_result
          if gate_result.enabled? && completed == true
            record_claim!(locked_run)
            operation_committed = true
          end
        end
      end

      SerializationResult.new(gate_result:, operation_committed:)
    end

    private

    def evaluate(locked_run, current_entry:)
      return result("run_missing") unless locked_run
      return result("run_source_unsupported") unless SUPPORTED_RUN_SOURCES.include?(locked_run.source)

      gate = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot.from_snapshot(
        locked_run.metadata.to_h[
          Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::METADATA_KEY
        ],
        run: locked_run,
        require_binding: true
      )
      return result("gate_snapshot_invalid") unless gate

      binding = gate.fetch("proposal_binding")
      identities = {
        candidate_identity: binding["candidate_identity"],
        destination_identity: binding["destination_identity"]
      }
      return result("start_gate_disabled", **identities) unless gate["setting_enabled"]
      return result("current_setting_disabled", **identities) unless current_entry.current_value == true
      return result("setting_generation_mismatch", **identities) unless
        gate["setting_generation"] ==
          Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot.setting_generation_for(
          current_entry
        )
      return result("proposal_binding_mismatch", **identities) unless proposal_binding_matches?(locked_run, binding:)

      claim_state = claim_state_for(locked_run, proposal_checksum: binding["proposal_checksum"])
      return result(claim_state, **identities) unless claim_state == "unclaimed"

      result("enabled", enabled: true, **identities)
    rescue ArgumentError, KeyError, TypeError
      result("gate_snapshot_invalid")
    end

    def proposal_binding_matches?(run, binding:)
      ocr_snapshot = run.ocr_result_snapshot.to_h
      proposal = Receipts::Processing::Contracts::ReferencePricingAdoptionProposal.from_snapshot(
        ocr_snapshot.dig("adoption_proposals", "reference_pricing"),
        ocr_snapshot:
      )
      proposal &&
        proposal["candidate_id"] == binding["candidate_identity"] &&
        proposal.dig("destination", "identity") == binding["destination_identity"] &&
        proposal["integrity_checksum"] == binding["proposal_checksum"]
    end

    def claim_state_for(run, proposal_checksum:)
      claim = run.metadata.to_h[CLAIM_METADATA_KEY]
      return "unclaimed" if claim.nil?
      return "claim_invalid" unless claim.is_a?(Hash) && claim.keys.sort == CLAIM_KEYS.sort
      return "claim_invalid" unless claim["schema_version"] == CLAIM_SCHEMA_VERSION
      return "claim_invalid" unless claim["proposal_checksum"].is_a?(String) &&
        claim["proposal_checksum"].match?(/\A[0-9a-f]{64}\z/)

      claim["proposal_checksum"] == proposal_checksum ? "already_claimed" : "claim_invalid"
    end

    def record_claim!(run)
      gate = run.metadata.to_h.fetch(
        Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::METADATA_KEY
      )
      metadata = run.metadata.to_h.deep_dup
      metadata[CLAIM_METADATA_KEY] = {
        "schema_version" => CLAIM_SCHEMA_VERSION,
        "proposal_checksum" => gate.dig("proposal_binding", "proposal_checksum")
      }
      run.update!(metadata:)
    end

    def result(reason, enabled: false, candidate_identity: nil, destination_identity: nil)
      bounded_reason = REASONS.include?(reason) ? reason : "gate_snapshot_invalid"
      Result.new(enabled:, reason: bounded_reason, candidate_identity:, destination_identity:)
    end
  end
end
