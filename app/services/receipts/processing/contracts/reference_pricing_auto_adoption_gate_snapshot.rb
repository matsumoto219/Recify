require "digest"

module Receipts::Processing::Contracts
  class ReferencePricingAutoAdoptionGateSnapshot
    SCHEMA_VERSION = "reference_pricing_auto_adoption_gate_v4"
    PREVIOUS_SCHEMA_VERSION = "reference_pricing_auto_adoption_gate_v3"
    LEGACY_SCHEMA_VERSION = "reference_pricing_auto_adoption_gate_v2"
    METADATA_KEY = "reference_pricing_auto_adoption_gate"
    CAPTURE_STAGE = "run_start"
    WRITER_CONTRACT_VERSION = "reference_pricing_auto_adoption_writer_v3"
    PREVIOUS_WRITER_CONTRACT_VERSION = "reference_pricing_auto_adoption_writer_v2"
    LEGACY_WRITER_CONTRACT_VERSION = "reference_pricing_auto_adoption_writer_v1"
    LINE_GROUP_BINDING_KIND = "azure_line_group"
    STRUCTURED_ITEM_BINDING_KIND = "azure_structured_item_reference"
    SUPPORTED_RUN_SOURCES = %w[upload batch_upload].freeze
    MAX_SERIALIZED_BYTES = 1280
    MAX_SEMANTIC_RECEIPT_BYTES = 64.kilobytes
    MAX_ID_BYTES = 160
    MAX_DATABASE_ID = (2**63) - 1
    RUN_KEY_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/.freeze
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    ROOT_KEYS = %w[
      schema_version capture_stage setting_key setting_enabled setting_generation
      eligibility_contract_version writer_contract_version
      run_key run_source receipt_state_at_start proposal_binding
    ].freeze
    PREVIOUS_ROOT_KEYS = %w[
      schema_version capture_stage setting_key setting_enabled setting_generation
      eligibility_contract_version writer_contract_version
      run_key run_source receipt_lock_version_at_start proposal_binding
    ].freeze
    RECEIPT_STATE_KEYS = %w[
      lock_version semantic_checksum image_attachment_id image_blob_id image_analyzed
    ].freeze
    ROW_GENERATION_KEYS = %w[kind id lock_version].freeze
    ABSENT_GENERATION_KEYS = %w[kind].freeze
    LEGACY_BINDING_KEYS = %w[
      candidate_identity destination_identity proposal_checksum receipt_lock_version
    ].freeze
    LINE_GROUP_BINDING_KEYS = (LEGACY_BINDING_KEYS + %w[binding_kind]).freeze
    STRUCTURED_ITEM_BINDING_KEYS = %w[
      binding_kind candidate_identity destination_identity selected_proposal_identity
      decision_contract_version proposal_checksum receipt_lock_version
    ].freeze
    STRUCTURED_ITEM_CANDIDATE_ID_PATTERN = /
      \A(?:
        azure_items_(?:0|[1-9]\d*) |
        azure_item_layout_p0
          _name_l(?:0|[1-9]\d*)
          _ref_l(?:0|[1-9]\d*)
          _qty_l(?:0|[1-9]\d*)
          _total_l(?:0|[1-9]\d*)
      )_item_calculation_mode\z
    /x.freeze

    class << self
      def capture_start(run_key:, run_source:, receipt:)
        return nil unless SUPPORTED_RUN_SOURCES.include?(run_source.to_s)
        receipt_state = receipt_state_for(receipt, run_key:)
        return nil unless receipt_state

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
          "receipt_state_at_start" => receipt_state,
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

        binding = proposal_binding_for(
          ocr_snapshot:,
          receipt_lock_version: receipt_lock_version_for(snapshot),
          schema_version: snapshot.fetch("schema_version")
        )
        return nil if binding.nil? && invalid_or_conflicting_binding_source?(
          ocr_snapshot:,
          schema_version: snapshot.fetch("schema_version")
        )
        return snapshot if binding.nil? && snapshot["proposal_binding"].nil?
        return nil if binding.nil?
        return nil if snapshot["proposal_binding"] && snapshot["proposal_binding"] != binding

        from_snapshot(snapshot.merge("proposal_binding" => binding), run:, require_binding: true)
      rescue ArgumentError, KeyError, TypeError
        nil
      end

      def from_snapshot(value, run: nil, require_binding: false)
        snapshot = normalized_hash(value)
        return nil unless supported_schema_version?(snapshot["schema_version"])
        return nil unless exact_keys?(snapshot, root_keys_for(snapshot["schema_version"]))
        return nil unless snapshot["capture_stage"] == CAPTURE_STAGE
        return nil unless snapshot["setting_key"] == SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY
        return nil unless boolean?(snapshot["setting_enabled"])
        return nil unless setting_generation_valid?(snapshot["setting_generation"])
        return nil if snapshot["setting_enabled"] && snapshot.dig("setting_generation", "kind") != "row"
        return nil unless contract_versions_valid?(snapshot)
        return nil unless bounded_string?(snapshot["run_key"], max_bytes: 36, pattern: RUN_KEY_PATTERN)
        return nil unless SUPPORTED_RUN_SOURCES.include?(snapshot["run_source"])
        return nil unless receipt_start_state_valid?(snapshot)
        return nil unless binding_valid?(
          snapshot["proposal_binding"],
          required: require_binding,
          schema_version: snapshot["schema_version"],
          receipt_lock_version: receipt_lock_version_for(snapshot)
        )
        return nil if run && (
          snapshot["run_key"] != run.run_key || snapshot["run_source"] != run.source
        )
        return nil unless JSON.generate(snapshot).bytesize <= MAX_SERIALIZED_BYTES

        deep_copy(snapshot)
      rescue EncodingError, JSON::GeneratorError, ArgumentError, KeyError, TypeError
        nil
      end

      def validated_receipt_lock_version(snapshot, receipt:)
        return nil unless receipt&.persisted?

        snapshot = from_snapshot(snapshot, require_binding: true)
        return nil unless snapshot

        if snapshot["schema_version"] != SCHEMA_VERSION
          expected = snapshot.dig("proposal_binding", "receipt_lock_version")
          return receipt.lock_version if bounded_integer?(expected, minimum: 0) && receipt.lock_version == expected

          return nil
        end

        start_state = snapshot["receipt_state_at_start"]
        current_state = receipt_state_for(receipt, run_key: snapshot["run_key"])
        return nil unless receipt_state_valid?(start_state) && receipt_state_valid?(current_state)
        return nil unless start_state["semantic_checksum"] == current_state["semantic_checksum"]
        return nil unless start_state["image_attachment_id"] == current_state["image_attachment_id"]
        return nil unless start_state["image_blob_id"] == current_state["image_blob_id"]

        start_lock_version = start_state["lock_version"]
        current_lock_version = current_state["lock_version"]
        if current_lock_version == start_lock_version
          return current_lock_version if start_state["image_analyzed"] == current_state["image_analyzed"]

          return nil
        end
        return nil unless start_lock_version < MAX_DATABASE_ID
        return nil unless current_lock_version == start_lock_version + 1
        return nil unless start_state["image_analyzed"] == false && current_state["image_analyzed"] == true

        current_lock_version
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

      def proposal_binding_for(ocr_snapshot:, receipt_lock_version:, schema_version: SCHEMA_VERSION)
        return nil unless ocr_snapshot.is_a?(Hash)
        return nil unless supported_schema_version?(schema_version)
        return nil unless bounded_integer?(receipt_lock_version, minimum: 0)

        line_group = line_group_binding_for(
          ocr_snapshot:,
          receipt_lock_version:,
          tagged: schema_version != LEGACY_SCHEMA_VERSION
        )
        return line_group if schema_version == LEGACY_SCHEMA_VERSION

        structured_item = structured_item_binding_for(ocr_snapshot:, receipt_lock_version:)
        bindings = [ line_group, structured_item ].compact

        bindings.sole if bindings.one?
      rescue EncodingError, JSON::GeneratorError, ArgumentError, KeyError, TypeError
        nil
      end

      private

      def line_group_binding_for(ocr_snapshot:, receipt_lock_version:, tagged:)
        adoption_proposals = hash_value(ocr_snapshot, "adoption_proposals")
        stored_proposal = hash_value(adoption_proposals, "reference_pricing")
        return nil if stored_proposal.nil?

        proposal = ReferencePricingAdoptionProposal.from_snapshot(stored_proposal, ocr_snapshot:)
        return nil if proposal.nil?

        binding = {
          "candidate_identity" => proposal["candidate_id"],
          "destination_identity" => proposal.dig("destination", "identity"),
          "proposal_checksum" => proposal["integrity_checksum"],
          "receipt_lock_version" => receipt_lock_version
        }
        binding["binding_kind"] = LINE_GROUP_BINDING_KIND if tagged
        binding
      end

      def invalid_or_conflicting_binding_source?(ocr_snapshot:, schema_version:)
        adoption_proposals = hash_value(ocr_snapshot, "adoption_proposals")
        stored_line_group = hash_value(adoption_proposals, "reference_pricing")
        line_group = line_group_binding_for(
          ocr_snapshot:,
          receipt_lock_version: 0,
          tagged: schema_version != LEGACY_SCHEMA_VERSION
        )
        return true if stored_line_group && line_group.nil?
        return false if schema_version == LEGACY_SCHEMA_VERSION

        stored_structured = hash_value(adoption_proposals, "item_calculation_modes")
        if stored_structured
          proposals = ItemCalculationModeProposalSet.from_snapshot(stored_structured, ocr_snapshot:)
          return true unless proposals.is_a?(Array)
        end

        structured = structured_item_binding_for(ocr_snapshot:, receipt_lock_version: 0)
        line_group.present? && structured.present?
      end

      def structured_item_binding_for(ocr_snapshot:, receipt_lock_version:)
        adoption_proposals = hash_value(ocr_snapshot, "adoption_proposals")
        stored_proposals = hash_value(adoption_proposals, "item_calculation_modes")
        return nil if stored_proposals.nil?

        proposals = ItemCalculationModeProposalSet.from_snapshot(stored_proposals, ocr_snapshot:)
        return nil unless proposals.is_a?(Array)

        batch = ItemCalculationModeDecision.evaluate_all(
          item_proposals: proposals,
          ocr_snapshot:,
          count_tax_semantics: "unknown",
          item_price_limit: ReceiptAmountService.receipt_item_price_max,
          item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max
        )
        return nil unless batch

        decisions = batch.decisions.select do |decision|
          decision.confirmed? && decision.selected_pricing_source_kind == "reference_quantity_price"
        end
        return nil unless decisions.one?

        decision = decisions.sole
        proposal = batch.proposals.find { |entry| entry["item_identity"] == decision.item_identity }
        return nil unless proposal && proposal["candidate_id"] == decision.candidate_id

        options = proposal["options"].select do |option|
          option["proposal_id"] == decision.selected_proposal_id &&
            option["pricing_source_kind"] == "reference_quantity_price"
        end
        return nil unless options.one?
        return nil unless options.sole.dig("source", "reference_price_tax_inclusion") == "gross"

        {
          "binding_kind" => STRUCTURED_ITEM_BINDING_KIND,
          "candidate_identity" => decision.candidate_id,
          "destination_identity" => decision.item_identity,
          "selected_proposal_identity" => decision.selected_proposal_id,
          "decision_contract_version" => decision.contract_version,
          "proposal_checksum" => proposal["integrity_checksum"],
          "receipt_lock_version" => receipt_lock_version
        }
      end

      def contract_versions_valid?(snapshot)
        return false unless snapshot["eligibility_contract_version"] ==
          ReferencePricingAutoAdoptionEligibility::CONTRACT_VERSION

        expected_writer_version = if snapshot["schema_version"] == LEGACY_SCHEMA_VERSION
          LEGACY_WRITER_CONTRACT_VERSION
        elsif snapshot["schema_version"] == PREVIOUS_SCHEMA_VERSION
          PREVIOUS_WRITER_CONTRACT_VERSION
        else
          WRITER_CONTRACT_VERSION
        end
        snapshot["writer_contract_version"] == expected_writer_version
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

      def binding_valid?(value, required:, schema_version:, receipt_lock_version:)
        return !required if value.nil?

        binding = normalized_hash(value)
        if schema_version == LEGACY_SCHEMA_VERSION
          return legacy_binding_valid?(binding, receipt_lock_version:)
        end

        case binding["binding_kind"]
        when LINE_GROUP_BINDING_KIND
          line_group_binding_valid?(binding, receipt_lock_version:)
        when STRUCTURED_ITEM_BINDING_KIND
          structured_item_binding_valid?(binding, receipt_lock_version:)
        else
          false
        end
      end

      def legacy_binding_valid?(binding, receipt_lock_version:)
        exact_keys?(binding, LEGACY_BINDING_KEYS) &&
          bounded_string?(binding["candidate_identity"], max_bytes: 128) &&
          bounded_string?(binding["destination_identity"], max_bytes: MAX_ID_BYTES) &&
          bounded_string?(binding["proposal_checksum"], max_bytes: 64, pattern: CHECKSUM_PATTERN) &&
          binding["receipt_lock_version"] == receipt_lock_version
      end

      def line_group_binding_valid?(binding, receipt_lock_version:)
        exact_keys?(binding, LINE_GROUP_BINDING_KEYS) &&
          binding["binding_kind"] == LINE_GROUP_BINDING_KIND &&
          legacy_binding_valid?(binding.except("binding_kind"), receipt_lock_version:)
      end

      def structured_item_binding_valid?(binding, receipt_lock_version:)
        exact_keys?(binding, STRUCTURED_ITEM_BINDING_KEYS) &&
          binding["binding_kind"] == STRUCTURED_ITEM_BINDING_KIND &&
          structured_item_proposal_identities_valid?(binding) &&
          bounded_string?(
            binding["destination_identity"],
            max_bytes: MAX_ID_BYTES,
            pattern: /\Aazure_structured_item_i\d+_s\d+_e\d+\z/
          ) &&
          binding["decision_contract_version"] == ItemCalculationModeDecision::CONTRACT_VERSION &&
          bounded_string?(binding["proposal_checksum"], max_bytes: 64, pattern: CHECKSUM_PATTERN) &&
          binding["receipt_lock_version"] == receipt_lock_version
      end

      def structured_item_proposal_identities_valid?(binding)
        candidate_identity = binding["candidate_identity"]
        selected_proposal_identity = binding["selected_proposal_identity"]
        return false unless bounded_string?(
          candidate_identity,
          max_bytes: MAX_ID_BYTES,
          pattern: STRUCTURED_ITEM_CANDIDATE_ID_PATTERN
        )
        return false unless bounded_string?(selected_proposal_identity, max_bytes: MAX_ID_BYTES)

        selected_proposal_identity == candidate_identity.sub(
          /_item_calculation_mode\z/,
          "_reference_quantity_price"
        )
      end

      def receipt_start_state_valid?(snapshot)
        if snapshot["schema_version"] == SCHEMA_VERSION
          receipt_state_valid?(snapshot["receipt_state_at_start"])
        else
          bounded_integer?(snapshot["receipt_lock_version_at_start"], minimum: 0)
        end
      end

      def receipt_state_valid?(value)
        state = normalized_hash(value)
        exact_keys?(state, RECEIPT_STATE_KEYS) &&
          bounded_integer?(state["lock_version"], minimum: 0) &&
          bounded_string?(state["semantic_checksum"], max_bytes: 64, pattern: CHECKSUM_PATTERN) &&
          bounded_integer?(state["image_attachment_id"], minimum: 1) &&
          bounded_integer?(state["image_blob_id"], minimum: 1) &&
          boolean?(state["image_analyzed"])
      end

      def receipt_state_for(receipt, run_key:)
        return nil unless receipt&.persisted?
        return nil unless bounded_string?(run_key, max_bytes: 36, pattern: RUN_KEY_PATTERN)

        attachment = receipt.image.attachment
        blob = attachment&.blob
        return nil unless attachment&.persisted? && blob&.persisted?

        semantic_attributes = deep_canonical_value(receipt.attributes.except("updated_at", "lock_version").as_json)
        serialized = JSON.generate(semantic_attributes)
        return nil if serialized.bytesize > MAX_SEMANTIC_RECEIPT_BYTES

        {
          "lock_version" => receipt.lock_version,
          "semantic_checksum" => Digest::SHA256.hexdigest(JSON.generate([ run_key, semantic_attributes ])),
          "image_attachment_id" => attachment.id,
          "image_blob_id" => blob.id,
          "image_analyzed" => blob.analyzed? == true
        }
      end

      def deep_canonical_value(value)
        case value
        when Hash
          normalized = {}
          value.each do |key, child|
            normalized_key = key.to_s
            raise ArgumentError if normalized.key?(normalized_key)

            normalized[normalized_key] = deep_canonical_value(child)
          end
          normalized.sort.to_h
        when Array
          value.map { |child| deep_canonical_value(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise ArgumentError
        end
      end

      def receipt_lock_version_for(snapshot)
        if snapshot["schema_version"] == SCHEMA_VERSION
          snapshot.dig("receipt_state_at_start", "lock_version")
        else
          snapshot["receipt_lock_version_at_start"]
        end
      end

      def supported_schema_version?(value)
        [ LEGACY_SCHEMA_VERSION, PREVIOUS_SCHEMA_VERSION, SCHEMA_VERSION ].include?(value)
      end

      def root_keys_for(schema_version)
        schema_version == SCHEMA_VERSION ? ROOT_KEYS : PREVIOUS_ROOT_KEYS
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
        return {} unless value.is_a?(Hash) && value.size <= [ ROOT_KEYS.size, PREVIOUS_ROOT_KEYS.size ].max

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
