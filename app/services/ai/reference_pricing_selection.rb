require "json"

module Ai
  class ReferencePricingSelection
    LEDGER_SCHEMA_VERSION = "reference_pricing_ocr_evidence_ledger_v1"

    DECISIONS = %w[select reject ambiguous].freeze
    REASONS_BY_DECISION = {
      "select" => %w[matched_reference_pricing],
      "reject" => %w[package_content discount not_reference_pricing],
      "ambiguous" => %w[multiple_plausible_options insufficient_evidence]
    }.freeze
    REASON_CODES = REASONS_BY_DECISION.values.flatten.freeze
    HANDLE_ROLES = %w[
      product_destination
      reference_price
      reference_quantity
      purchased_quantity
      tax_inclusion
    ].freeze
    VALIDATION_REASONS = %w[
      accepted
      selection_missing
      selection_oversized
      malformed_selection
      invalid_decision
      invalid_reason
      unknown_pair
      decision_field_mismatch
    ].freeze

    MAX_OPTIONS = 16
    MAX_CONTEXT_LINES = 150
    MAX_INPUT_BYTES = 32 * 1024
    MAX_OUTPUT_BYTES = 4 * 1024
    MAX_CANDIDATE_ID_BYTES = 128
    MAX_DESTINATION_ID_BYTES = 160

    LEDGER_ROOT_KEYS = %w[
      schema_version creation_stage option_count handle_count options integrity_checksum
    ].freeze
    INPUT_KEYS = %w[ledger_checksum options].freeze
    INPUT_OPTION_KEYS = %w[candidate_id destination_id evidence_lines].freeze
    OUTPUT_KEYS = %w[decision candidate_id destination_id reason_code].freeze

    CANDIDATE_ID_PATTERN = /\Aazure_line_group_evidence_v1_[0-9a-f]{64}\z/.freeze
    DESTINATION_ID_PATTERN = /\Aazure_line_group_destination_p\d+_name_l\d+_s\d+_e\d+_ref_l\d+_qty_l\d+\z/.freeze
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze

    class << self
      def input_from_ledger(value, context_line_count:)
        ledger = exact_hash(value, LEDGER_ROOT_KEYS)
        return unless ledger
        return unless ledger["schema_version"] == LEDGER_SCHEMA_VERSION
        return unless ledger["creation_stage"] == "ocr_validation"
        return unless checksum?(ledger["integrity_checksum"])
        return unless bounded_context_line_count?(context_line_count)
        return unless ledger["options"].is_a?(Array)
        return unless ledger["options"].size.between?(1, MAX_OPTIONS)
        return unless ledger["option_count"] == ledger["options"].size

        options = ledger["options"].map do |option|
          input_option(option, context_line_count:)
        end
        return if options.any?(&:nil?)
        return unless unique_values?(options, "candidate_id")
        return unless unique_values?(options, "destination_id")

        normalized_input(
          "ledger_checksum" => ledger.fetch("integrity_checksum"),
          "options" => options.sort_by do |option|
            [ option.fetch("evidence_lines").values.min, option.fetch("candidate_id") ]
          end
        )
      rescue EncodingError, JSON::GeneratorError, SystemStackError, TypeError
        nil
      end

      def input?(value)
        normalized_input(value).present?
      end

      def sanitize(output:, input:)
        normalized = normalized_input(input)
        return unless normalized

        reason = output_validation_reason(output, input: normalized)
        return rejected_result(normalized, reason) unless reason == "accepted"

        selection = exact_hash(output, OUTPUT_KEYS)
        accepted_result(normalized, selection)
      rescue EncodingError, JSON::GeneratorError, SystemStackError, TypeError
        rejected_result(normalized, "malformed_selection") if normalized
      end

      private

      def input_option(value, context_line_count:)
        option = stringify_hash(value)
        return unless option

        candidate_id = bounded_string(
          option["candidate_id"],
          max_bytes: MAX_CANDIDATE_ID_BYTES,
          pattern: CANDIDATE_ID_PATTERN
        )
        destination_id = bounded_string(
          option["destination_id"],
          max_bytes: MAX_DESTINATION_ID_BYTES,
          pattern: DESTINATION_ID_PATTERN
        )
        handles = option["handles"]
        return unless candidate_id && destination_id
        return unless handles.is_a?(Array) && handles.size == HANDLE_ROLES.size

        evidence_lines = handles.each_with_object({}) do |handle, result|
          normalized_handle = stringify_hash(handle)
          return unless normalized_handle

          role = normalized_handle["role"]
          line_index = normalized_handle["line_index"]
          return unless HANDLE_ROLES.include?(role)
          return if result.key?(role)
          return unless line_index.is_a?(Integer) && line_index.between?(0, context_line_count - 1)

          result[role] = line_index
        end
        return unless evidence_lines.keys == HANDLE_ROLES

        {
          "candidate_id" => candidate_id,
          "destination_id" => destination_id,
          "evidence_lines" => evidence_lines
        }
      end

      def normalized_input(value)
        input = exact_hash(value, INPUT_KEYS)
        return unless input
        return unless checksum?(input["ledger_checksum"])
        return unless input["options"].is_a?(Array)
        return unless input["options"].size.between?(1, MAX_OPTIONS)

        options = input["options"].map { |option| normalized_input_option(option) }
        return if options.any?(&:nil?)
        return unless unique_values?(options, "candidate_id")
        return unless unique_values?(options, "destination_id")

        normalized = {
          "ledger_checksum" => input.fetch("ledger_checksum"),
          "options" => options
        }
        return if serialized_bytes(normalized) > MAX_INPUT_BYTES

        normalized
      end

      def normalized_input_option(value)
        option = exact_hash(value, INPUT_OPTION_KEYS)
        return unless option

        candidate_id = bounded_string(
          option["candidate_id"],
          max_bytes: MAX_CANDIDATE_ID_BYTES,
          pattern: CANDIDATE_ID_PATTERN
        )
        destination_id = bounded_string(
          option["destination_id"],
          max_bytes: MAX_DESTINATION_ID_BYTES,
          pattern: DESTINATION_ID_PATTERN
        )
        evidence_lines = exact_hash(option["evidence_lines"], HANDLE_ROLES)
        return unless candidate_id && destination_id && evidence_lines
        return unless evidence_lines.values.all? do |index|
          index.is_a?(Integer) && index.between?(0, MAX_CONTEXT_LINES - 1)
        end

        {
          "candidate_id" => candidate_id,
          "destination_id" => destination_id,
          "evidence_lines" => evidence_lines
        }
      end

      def output_validation_reason(output, input:)
        return "selection_missing" if output.nil?
        return "malformed_selection" unless output.is_a?(Hash)
        return "selection_oversized" if serialized_bytes(output) > MAX_OUTPUT_BYTES

        selection = exact_hash(output, OUTPUT_KEYS)
        return "malformed_selection" unless selection

        decision = selection["decision"]
        reason_code = selection["reason_code"]
        return "invalid_decision" unless DECISIONS.include?(decision)
        return "invalid_reason" unless REASONS_BY_DECISION.fetch(decision).include?(reason_code)

        if decision == "select"
          candidate_id = bounded_string(
            selection["candidate_id"],
            max_bytes: MAX_CANDIDATE_ID_BYTES,
            pattern: CANDIDATE_ID_PATTERN
          )
          destination_id = bounded_string(
            selection["destination_id"],
            max_bytes: MAX_DESTINATION_ID_BYTES,
            pattern: DESTINATION_ID_PATTERN
          )
          return "unknown_pair" unless candidate_id && destination_id
          return "unknown_pair" unless input.fetch("options").any? do |option|
            option["candidate_id"] == candidate_id && option["destination_id"] == destination_id
          end
        elsif !selection["candidate_id"].nil? || !selection["destination_id"].nil?
          return "decision_field_mismatch"
        end

        "accepted"
      end

      def accepted_result(input, selection)
        result = {
          "ledger_checksum" => input.fetch("ledger_checksum"),
          "decision" => selection.fetch("decision"),
          "reason_code" => selection.fetch("reason_code"),
          "validation_state" => "accepted",
          "validation_reason" => "accepted"
        }
        if selection["decision"] == "select"
          result["candidate_id"] = selection.fetch("candidate_id")
          result["destination_id"] = selection.fetch("destination_id")
        end
        result
      end

      def rejected_result(input, reason)
        reason = "malformed_selection" unless VALIDATION_REASONS.include?(reason)
        {
          "ledger_checksum" => input.fetch("ledger_checksum"),
          "validation_state" => "rejected",
          "validation_reason" => reason
        }
      end

      def exact_hash(value, allowed_keys)
        normalized = stringify_hash(value)
        return unless normalized

        normalized if normalized.keys.sort == allowed_keys.sort
      end

      def stringify_hash(value)
        return unless value.respond_to?(:to_h)

        source = value.to_h
        return unless source.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }

        source.each_with_object({}) do |(key, child), normalized|
          string_key = key.to_s
          return if normalized.key?(string_key)

          normalized[string_key] = child
        end
      rescue SystemStackError, TypeError
        nil
      end

      def unique_values?(values, key)
        entries = values.pluck(key)
        entries.uniq.size == entries.size
      end

      def checksum?(value)
        bounded_string(value, max_bytes: 64, pattern: CHECKSUM_PATTERN).present?
      end

      def bounded_context_line_count?(value)
        value.is_a?(Integer) && value.between?(1, MAX_CONTEXT_LINES)
      end

      def bounded_string(value, max_bytes:, pattern: nil)
        return unless value.is_a?(String) && value.valid_encoding?
        return unless value.encoding == Encoding::UTF_8 || value.ascii_only?
        return if value.empty? || value.bytesize > max_bytes
        return if value.match?(CONTROL_CHARACTER_PATTERN)
        return if pattern && !value.match?(pattern)

        value
      rescue ArgumentError, Encoding::CompatibilityError
        nil
      end

      def serialized_bytes(value)
        JSON.generate(value).bytesize
      rescue JSON::GeneratorError, SystemStackError
        MAX_OUTPUT_BYTES + 1
      end
    end
  end
end
