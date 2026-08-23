module Receipts::Processing::Contracts
  class ReferencePricingAutoAdoptionGateSnapshot
    SCHEMA_VERSION = "reference_pricing_auto_adoption_gate_v2"
    METADATA_KEY = "reference_pricing_auto_adoption_gate"
    CAPTURE_STAGE = "run_start"
    WRITER_CONTRACT_VERSION = "reference_pricing_auto_adoption_writer_v1"
    SUPPORTED_RUN_SOURCES = %w[upload batch_upload].freeze
    MAX_SERIALIZED_BYTES = 1024
    MAX_ID_BYTES = 160
    MAX_DATABASE_ID = (2**63) - 1
    RUN_KEY_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/.freeze
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    ROOT_KEYS = %w[
      schema_version capture_stage setting_key setting_enabled setting_generation
      eligibility_contract_version writer_contract_version
      run_key run_source receipt_lock_version_at_start proposal_binding
    ].freeze
    ROW_GENERATION_KEYS = %w[kind id lock_version].freeze
    ABSENT_GENERATION_KEYS = %w[kind].freeze
    BINDING_KEYS = %w[
      candidate_identity destination_identity proposal_checksum receipt_lock_version
    ].freeze

    class << self
      def capture_start(run_key:, run_source:, receipt_lock_version:)
        return nil unless SUPPORTED_RUN_SOURCES.include?(run_source.to_s)
        return nil unless bounded_integer?(receipt_lock_version, minimum: 0)

        entry = SystemSettings.fetch(SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY)
        snapshot = {
          "schema_version" => SCHEMA_VERSION,
          "capture_stage" => CAPTURE_STAGE,
          "setting_key" => SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
          "setting_enabled" => entry.current_value == true,
          "setting_generation" => setting_generation_for(entry),
          "eligibility_contract_version" => ReferencePricingAutoAdoptionEligibility::CONTRACT_VERSION,
          "writer_contract_version" => WRITER_CONTRACT_VERSION,
          "run_key" => run_key,
          "run_source" => run_source.to_s,
          "receipt_lock_version_at_start" => receipt_lock_version,
          "proposal_binding" => nil
        }

        from_snapshot(snapshot)
      rescue ActiveRecord::ActiveRecordError,
        SystemSettings::UnknownKeyError,
        SystemSettings::ValidationError,
        ArgumentError,
        TypeError
        nil
      end

      def bind(value, run:, ocr_snapshot:)
        snapshot = from_snapshot(value, run:, require_binding: false)
        return nil if snapshot.nil?

        return nil unless ocr_snapshot.is_a?(Hash)

        adoption_proposals = hash_value(ocr_snapshot, "adoption_proposals")
        stored_proposal = hash_value(adoption_proposals, "reference_pricing")
        proposal = ReferencePricingAdoptionProposal.from_snapshot(
          stored_proposal,
          ocr_snapshot:
        )
        return snapshot if stored_proposal.nil? && snapshot["proposal_binding"].nil?
        return nil if proposal.nil?

        binding = binding_for(
          proposal,
          receipt_lock_version: snapshot.fetch("receipt_lock_version_at_start")
        )
        return nil if snapshot["proposal_binding"] && snapshot["proposal_binding"] != binding

        from_snapshot(snapshot.merge("proposal_binding" => binding), run:, require_binding: true)
      rescue ArgumentError, KeyError, TypeError
        nil
      end

      def from_snapshot(value, run: nil, require_binding: false)
        snapshot = normalized_hash(value)
        return nil unless exact_keys?(snapshot, ROOT_KEYS)
        return nil unless snapshot["schema_version"] == SCHEMA_VERSION
        return nil unless snapshot["capture_stage"] == CAPTURE_STAGE
        return nil unless snapshot["setting_key"] == SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY
        return nil unless boolean?(snapshot["setting_enabled"])
        return nil unless setting_generation_valid?(snapshot["setting_generation"])
        return nil if snapshot["setting_enabled"] && snapshot.dig("setting_generation", "kind") != "row"
        return nil unless snapshot["eligibility_contract_version"] ==
          ReferencePricingAutoAdoptionEligibility::CONTRACT_VERSION
        return nil unless snapshot["writer_contract_version"] == WRITER_CONTRACT_VERSION
        return nil unless bounded_string?(snapshot["run_key"], max_bytes: 36, pattern: RUN_KEY_PATTERN)
        return nil unless SUPPORTED_RUN_SOURCES.include?(snapshot["run_source"])
        return nil unless bounded_integer?(snapshot["receipt_lock_version_at_start"], minimum: 0)
        return nil unless binding_valid?(
          snapshot["proposal_binding"],
          required: require_binding,
          receipt_lock_version: snapshot["receipt_lock_version_at_start"]
        )
        return nil if run && (
          snapshot["run_key"] != run.run_key || snapshot["run_source"] != run.source
        )
        return nil unless JSON.generate(snapshot).bytesize <= MAX_SERIALIZED_BYTES

        deep_copy(snapshot)
      rescue EncodingError, JSON::GeneratorError, ArgumentError, KeyError, TypeError
        nil
      end

      def setting_generation_for(entry)
        setting = entry&.setting
        return { "kind" => "absent" } unless setting

        {
          "kind" => "row",
          "id" => setting.id,
          "lock_version" => setting.lock_version
        }
      end

      private

      def binding_for(proposal, receipt_lock_version:)
        {
          "candidate_identity" => proposal["candidate_id"],
          "destination_identity" => proposal.dig("destination", "identity"),
          "proposal_checksum" => proposal["integrity_checksum"],
          "receipt_lock_version" => receipt_lock_version
        }
      end

      def setting_generation_valid?(value)
        generation = normalized_hash(value)
        case generation["kind"]
        when "absent"
          exact_keys?(generation, ABSENT_GENERATION_KEYS)
        when "row"
          exact_keys?(generation, ROW_GENERATION_KEYS) &&
            bounded_integer?(generation["id"], minimum: 1) &&
            bounded_integer?(generation["lock_version"], minimum: 0)
        else
          false
        end
      end

      def binding_valid?(value, required:, receipt_lock_version:)
        return !required if value.nil?

        binding = normalized_hash(value)
        exact_keys?(binding, BINDING_KEYS) &&
          bounded_string?(binding["candidate_identity"], max_bytes: 128) &&
          bounded_string?(binding["destination_identity"], max_bytes: MAX_ID_BYTES) &&
          bounded_string?(binding["proposal_checksum"], max_bytes: 64, pattern: CHECKSUM_PATTERN) &&
          binding["receipt_lock_version"] == receipt_lock_version
      end

      def bounded_integer?(value, minimum:)
        value.is_a?(Integer) && value.between?(minimum, MAX_DATABASE_ID)
      end

      def boolean?(value)
        value == true || value == false
      end

      def bounded_string?(value, max_bytes:, pattern: nil)
        value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, max_bytes) &&
          !value.match?(ReferencePricingAdoptionProposal::CONTROL_CHARACTER_PATTERN) &&
          (!pattern || value.match?(pattern))
      rescue EncodingError, ArgumentError, TypeError
        false
      end

      def exact_keys?(value, expected)
        value.is_a?(Hash) && value.keys.sort == expected.sort
      end

      def normalized_hash(value)
        return {} unless value.is_a?(Hash) && value.size <= ROOT_KEYS.size

        normalized = {}
        value.each do |key, child|
          return {} unless key.is_a?(String) || key.is_a?(Symbol)

          normalized_key = key.to_s
          return {} if normalized.key?(normalized_key)

          normalized[normalized_key] = normalize_child(child, depth: 1)
        end
        normalized
      rescue EncodingError, ArgumentError, SystemStackError, TypeError
        {}
      end

      def normalize_child(value, depth:)
        raise ArgumentError if depth > 3

        case value
        when Hash
          raise ArgumentError if value.size > ROOT_KEYS.size

          normalized = {}
          value.each do |key, child|
            raise ArgumentError unless key.is_a?(String) || key.is_a?(Symbol)

            normalized_key = key.to_s
            raise ArgumentError if normalized.key?(normalized_key)

            normalized[normalized_key] = normalize_child(child, depth: depth + 1)
          end
          normalized
        when String
          raise ArgumentError unless value.valid_encoding? && value.bytesize <= 256
          raise ArgumentError if value.match?(ReferencePricingAdoptionProposal::CONTROL_CHARACTER_PATTERN)

          value.dup
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          raise ArgumentError
        end
      end

      def hash_value(value, expected_key)
        return unless value.is_a?(Hash) && value.size <= 24

        matching_keys = value.keys.select do |key|
          (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s == expected_key
        end
        return unless matching_keys.one?

        value[matching_keys.sole]
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
