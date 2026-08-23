require "digest"

module Receipts::Processing::Contracts
  class ReferencePricingOcrEvidenceLedger
    SCHEMA_VERSION = "reference_pricing_ocr_evidence_ledger_v1"
    CREATION_STAGE = "ocr_validation"
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"
    SOURCE_KIND = "azure_line_group"
    PROVIDER_MODEL_ID = "prebuilt-receipt"
    PROVIDER_API_VERSION = "2024-11-30"
    VALIDATION_STATE = "valid"
    VALIDATION_CONTRACT_VERSION = "azure_line_group_v1"
    ANALYSIS_PROFILE_COUNTRY_CODE = "JPN"
    STRING_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
    HANDLE_ROLES = %w[
      product_destination
      reference_price
      reference_quantity
      purchased_quantity
      tax_inclusion
    ].freeze

    MAX_OPTIONS = 16
    HANDLES_PER_OPTION = HANDLE_ROLES.size
    MAX_TOTAL_HANDLES = MAX_OPTIONS * HANDLES_PER_OPTION
    MAX_SERIALIZED_BYTES = 32 * 1024
    MAX_CANDIDATE_ID_BYTES = 128
    MAX_DESTINATION_ID_BYTES = 160
    MAX_HANDLE_ID_BYTES = 128
    MAX_SOURCE_PATH_BYTES = 256
    MAX_CONTEXT_LINE_BYTES = 500
    MAX_LINE_INDEX = 149
    MAX_PROVIDER_SPAN = 10_000_000

    ROOT_KEYS = %w[
      schema_version
      creation_stage
      option_count
      handle_count
      options
      integrity_checksum
    ].freeze
    OPTION_KEYS = %w[
      candidate_id
      destination_id
      source_kind
      provider_model_id
      provider_api_version
      string_index_type
      validation_state
      validation_contract_version
      analysis_profile_country_code
      page_index
      reference_line_index
      purchased_quantity_line_index
      handles
    ].freeze
    HANDLE_KEYS = %w[
      handle_id
      role
      source_field_path
      page_index
      line_index
      string_index_type
      provider_span_start
      provider_span_end
    ].freeze

    CANDIDATE_ID_NAMESPACE = "azure_line_group_evidence_v1"
    CANDIDATE_ID_PREFIX = "#{CANDIDATE_ID_NAMESPACE}_"
    CANDIDATE_ID_PATTERN = /\A#{Regexp.escape(CANDIDATE_ID_PREFIX)}[0-9a-f]{64}\z/.freeze
    DESTINATION_ID_PATTERN =
      /\Aazure_line_group_destination_p(?<page>\d+)_name_l(?<name_line>\d+)_s(?<start>\d+)_e(?<end>\d+)_ref_l(?<reference_line>\d+)_qty_l(?<purchased_line>\d+)\z/.freeze
    HANDLE_ID_PREFIX = "reference_pricing_handle_v1_"
    HANDLE_ID_PATTERN = /\A#{Regexp.escape(HANDLE_ID_PREFIX)}[0-9a-f]{64}\z/.freeze
    LINE_PATH_PATTERN = /\Apages\[(?<page>\d+)\]\.lines\[(?<line>\d+)\]\z/.freeze
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    CONTROL_CHARACTER_PATTERN =
      /[\u0000-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze

    class << self
      def build(options:, ocr_snapshot:, source_lines:, source_case_preserved_lines:)
        context = snapshot_context(ocr_snapshot)
        return nil unless source_lines_lossless?(
          context,
          source_lines:,
          source_case_preserved_lines:
        )

        normalized_options = normalize_options(options, context:)
        return nil if normalized_options.nil?

        ledger_for(normalized_options, context:)
      rescue EncodingError, ArgumentError, KeyError, SystemStackError, TypeError
        nil
      end

      def from_snapshot(value, ocr_snapshot:)
        root = exact_hash(value, ROOT_KEYS)
        return nil unless root
        return nil unless root["schema_version"] == SCHEMA_VERSION
        return nil unless root["creation_stage"] == CREATION_STAGE
        return nil unless bounded_integer(root["option_count"], maximum: MAX_OPTIONS)&.positive?
        return nil unless bounded_integer(root["handle_count"], maximum: MAX_TOTAL_HANDLES)&.positive?
        return nil unless bounded_string(
          root["integrity_checksum"],
          max_bytes: 64,
          pattern: CHECKSUM_PATTERN
        )

        context = snapshot_context(ocr_snapshot)
        options = normalize_options(root["options"], context:)
        return nil if options.nil?
        return nil unless root["option_count"] == options.size
        return nil unless root["handle_count"] == options.sum { |option| option.fetch("handles").size }

        canonical = ledger_for(options, context:)
        canonical if canonical == root
      rescue EncodingError, ArgumentError, KeyError, SystemStackError, TypeError
        nil
      end

      private

      def ledger_for(options, context:)
        payload = {
          "schema_version" => SCHEMA_VERSION,
          "creation_stage" => CREATION_STAGE,
          "option_count" => options.size,
          "handle_count" => options.sum { |option| option.fetch("handles").size },
          "options" => options
        }
        integrity_context = {
          "lines" => context.fetch(:lines),
          "case_preserved_lines" => context.fetch(:case_preserved_lines)
        }
        ledger = payload.merge(
          "integrity_checksum" => checksum(
            "ledger" => payload,
            "ocr_context" => integrity_context
          )
        )
        return nil if JSON.generate(ledger).bytesize > MAX_SERIALIZED_BYTES

        ledger
      rescue JSON::GeneratorError
        nil
      end

      def normalize_options(value, context:)
        return unless context
        return unless value.is_a?(Array) && value.size.between?(1, MAX_OPTIONS)

        options = value.map { |option| normalize_option(option, context:) }
        return if options.any?(&:nil?)

        options.sort_by! do |option|
          option.values_at(
            "page_index",
            "reference_line_index",
            "purchased_quantity_line_index",
            "candidate_id"
          )
        end
        return unless unique_values?(options, "candidate_id")
        return unless unique_values?(options, "destination_id")

        handle_ids = options.flat_map do |option|
          option.fetch("handles").pluck("handle_id")
        end
        return unless handle_ids.size <= MAX_TOTAL_HANDLES && handle_ids.uniq.size == handle_ids.size

        options
      end

      def normalize_option(value, context:)
        option = exact_hash(value, OPTION_KEYS)
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
        string_index_type = enum_string(option["string_index_type"], STRING_INDEX_TYPES)
        page_index = bounded_integer(option["page_index"], maximum: 0)
        reference_line_index = bounded_integer(option["reference_line_index"], maximum: MAX_LINE_INDEX)
        purchased_line_index = bounded_integer(
          option["purchased_quantity_line_index"],
          maximum: MAX_LINE_INDEX
        )
        return unless candidate_id && destination_id && string_index_type
        return unless page_index == 0
        return unless reference_line_index && purchased_line_index == reference_line_index + 1
        return unless purchased_line_index < context.fetch(:line_count)
        return unless option["source_kind"] == SOURCE_KIND
        return unless option["provider_model_id"] == PROVIDER_MODEL_ID
        return unless option["provider_api_version"] == PROVIDER_API_VERSION
        return unless option["validation_state"] == VALIDATION_STATE
        return unless option["validation_contract_version"] == VALIDATION_CONTRACT_VERSION
        return unless option["analysis_profile_country_code"] == ANALYSIS_PROFILE_COUNTRY_CODE

        handles = normalize_handles(
          option["handles"],
          page_index:,
          reference_line_index:,
          purchased_line_index:,
          string_index_type:
        )
        return if handles.nil?
        return unless destination_matches_option?(
          destination_id,
          page_index:,
          reference_line_index:,
          purchased_line_index:,
          product_handle: handles.fetch(0)
        )
        return unless component_spans_ordered?(handles)
        return unless candidate_id == canonical_candidate_id(destination_id, handles)

        {
          "candidate_id" => candidate_id,
          "destination_id" => destination_id,
          "source_kind" => SOURCE_KIND,
          "provider_model_id" => PROVIDER_MODEL_ID,
          "provider_api_version" => PROVIDER_API_VERSION,
          "string_index_type" => string_index_type,
          "validation_state" => VALIDATION_STATE,
          "validation_contract_version" => VALIDATION_CONTRACT_VERSION,
          "analysis_profile_country_code" => ANALYSIS_PROFILE_COUNTRY_CODE,
          "page_index" => page_index,
          "reference_line_index" => reference_line_index,
          "purchased_quantity_line_index" => purchased_line_index,
          "handles" => handles
        }
      end

      def normalize_handles(value, page_index:, reference_line_index:, purchased_line_index:, string_index_type:)
        return unless value.is_a?(Array) && value.size == HANDLES_PER_OPTION

        handles = value.map do |handle|
          normalize_handle(
            handle,
            page_index:,
            reference_line_index:,
            purchased_line_index:,
            string_index_type:
          )
        end
        return if handles.any?(&:nil?)
        return unless handles.pluck("role") == HANDLE_ROLES
        return unless unique_values?(handles, "handle_id")

        handles
      end

      def normalize_handle(
        value,
        page_index:,
        reference_line_index:,
        purchased_line_index:,
        string_index_type:
      )
        handle = exact_hash(value, HANDLE_KEYS)
        return unless handle

        handle_id = bounded_string(
          handle["handle_id"],
          max_bytes: MAX_HANDLE_ID_BYTES,
          pattern: HANDLE_ID_PATTERN
        )
        role = enum_string(handle["role"], HANDLE_ROLES)
        path = bounded_string(
          handle["source_field_path"],
          max_bytes: MAX_SOURCE_PATH_BYTES,
          pattern: LINE_PATH_PATTERN
        )
        handle_page_index = bounded_integer(handle["page_index"], maximum: 0)
        line_index = bounded_integer(handle["line_index"], maximum: MAX_LINE_INDEX)
        span_start = bounded_integer(handle["provider_span_start"], maximum: MAX_PROVIDER_SPAN)
        span_end = bounded_integer(handle["provider_span_end"], maximum: MAX_PROVIDER_SPAN)
        return unless handle_id && role && path
        return unless handle_page_index == page_index
        return unless line_index == expected_line_index(
          role,
          reference_line_index:,
          purchased_line_index:
        )
        return unless handle["string_index_type"] == string_index_type
        return unless span_start && span_end && span_start < span_end

        path_match = LINE_PATH_PATTERN.match(path)
        return unless Integer(path_match[:page], 10) == page_index
        return unless Integer(path_match[:line], 10) == line_index

        normalized = {
          "handle_id" => handle_id,
          "role" => role,
          "source_field_path" => path,
          "page_index" => handle_page_index,
          "line_index" => line_index,
          "string_index_type" => string_index_type,
          "provider_span_start" => span_start,
          "provider_span_end" => span_end
        }
        normalized if handle_id == canonical_handle_id(normalized)
      rescue ArgumentError
        nil
      end

      def expected_line_index(role, reference_line_index:, purchased_line_index:)
        role == "purchased_quantity" ? purchased_line_index : reference_line_index
      end

      def destination_matches_option?(
        destination_id,
        page_index:,
        reference_line_index:,
        purchased_line_index:,
        product_handle:
      )
        match = DESTINATION_ID_PATTERN.match(destination_id)
        return false unless match

        Integer(match[:page], 10) == page_index &&
          Integer(match[:name_line], 10) == reference_line_index &&
          Integer(match[:reference_line], 10) == reference_line_index &&
          Integer(match[:purchased_line], 10) == purchased_line_index &&
          Integer(match[:start], 10) == product_handle.fetch("provider_span_start") &&
          Integer(match[:end], 10) == product_handle.fetch("provider_span_end")
      rescue ArgumentError, KeyError
        false
      end

      def component_spans_ordered?(handles)
        by_role = handles.index_by { |handle| handle.fetch("role") }
        destination = by_role.fetch("product_destination")
        tax = by_role.fetch("tax_inclusion")
        price = by_role.fetch("reference_price")
        reference_quantity = by_role.fetch("reference_quantity")
        purchased_quantity = by_role.fetch("purchased_quantity")

        destination.fetch("provider_span_end") <= tax.fetch("provider_span_start") &&
          tax.fetch("provider_span_end") <= price.fetch("provider_span_start") &&
          price.fetch("provider_span_end") <= reference_quantity.fetch("provider_span_start") &&
          reference_quantity.fetch("provider_span_end") <= purchased_quantity.fetch("provider_span_start")
      rescue KeyError
        false
      end

      def snapshot_context(value)
        snapshot = bounded_hash_values(
          value,
          required_keys: %w[schema_version success lines case_preserved_lines truncated],
          maximum_entries: 24
        )
        return unless snapshot
        return unless snapshot.fetch("schema_version").to_s == OCR_RESULT_SCHEMA_VERSION
        return unless snapshot.fetch("success") == true

        lines = snapshot.fetch("lines")
        case_preserved_lines = snapshot.fetch("case_preserved_lines")
        truncated = bounded_hash_values(
          snapshot.fetch("truncated"),
          required_keys: %w[lines case_preserved_lines],
          maximum_entries: 16
        )
        return unless lines.is_a?(Array) && lines.size.between?(1, MAX_LINE_INDEX + 1)
        return unless case_preserved_lines.is_a?(Array) && case_preserved_lines.size == lines.size
        return unless truncated
        return unless truncated.fetch("lines") == false && truncated.fetch("case_preserved_lines") == false

        normalized_lines = bounded_context_lines(lines)
        normalized_case_preserved_lines = bounded_context_lines(case_preserved_lines)
        return unless normalized_lines && normalized_case_preserved_lines

        {
          line_count: normalized_lines.size,
          lines: normalized_lines,
          case_preserved_lines: normalized_case_preserved_lines
        }
      end

      def source_lines_lossless?(context, source_lines:, source_case_preserved_lines:)
        return false unless context

        bounded_context_lines(source_lines) == context.fetch(:lines) &&
          bounded_context_lines(source_case_preserved_lines) == context.fetch(:case_preserved_lines)
      end

      def bounded_context_lines(value)
        return unless value.is_a?(Array) && value.size.between?(1, MAX_LINE_INDEX + 1)

        lines = value.map { |line| bounded_context_line(line) }
        lines unless lines.any?(&:nil?)
      end

      def bounded_context_line(value)
        return unless value.is_a?(String) && value.valid_encoding?
        return unless value.encoding == Encoding::UTF_8 || value.ascii_only?
        return if value.bytesize > MAX_CONTEXT_LINE_BYTES
        return if value.match?(CONTROL_CHARACTER_PATTERN)

        value.dup.freeze
      rescue Encoding::CompatibilityError
        nil
      end

      def canonical_handle_id(handle)
        material = handle.values_at(
          "role",
          "source_field_path",
          "page_index",
          "line_index",
          "string_index_type",
          "provider_span_start",
          "provider_span_end"
        )
        "#{HANDLE_ID_PREFIX}#{Digest::SHA256.hexdigest(material.join("\0"))}"
      end

      def canonical_candidate_id(destination_id, handles)
        material = [
          CANDIDATE_ID_NAMESPACE,
          destination_id,
          *handles.flat_map do |handle|
            handle.values_at(
              "role",
              "source_field_path",
              "page_index",
              "line_index",
              "string_index_type",
              "provider_span_start",
              "provider_span_end"
            )
          end
        ]
        "#{CANDIDATE_ID_PREFIX}#{Digest::SHA256.hexdigest(material.join("\0"))}"
      end

      def exact_hash(value, allowed_keys)
        return unless value.is_a?(Hash) && value.size == allowed_keys.size

        normalized = {}
        value.each do |key, child|
          return unless key.is_a?(String) || key.is_a?(Symbol)

          normalized_key = key.to_s
          return unless allowed_keys.include?(normalized_key)
          return if normalized.key?(normalized_key)

          normalized[normalized_key] = child
        end
        normalized if normalized.keys.sort == allowed_keys.sort
      end

      def bounded_hash_values(value, required_keys:, maximum_entries:)
        return unless value.is_a?(Hash) && value.size <= maximum_entries

        required_keys.to_h do |expected_key|
          matching_keys = value.keys.select do |key|
            (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s == expected_key
          end
          return unless matching_keys.one?

          [ expected_key, value.fetch(matching_keys.sole) ]
        end
      end

      def enum_string(value, allowed)
        value if value.is_a?(String) && allowed.include?(value)
      end

      def bounded_string(value, max_bytes:, pattern: nil)
        return unless value.is_a?(String) && value.valid_encoding?
        return unless value.encoding == Encoding::UTF_8 || value.ascii_only?
        return if value.empty? || value.bytesize > max_bytes
        return if value.match?(CONTROL_CHARACTER_PATTERN)
        return if pattern && !value.match?(pattern)

        value.dup.freeze
      rescue Encoding::CompatibilityError
        nil
      end

      def bounded_integer(value, maximum:)
        value if value.is_a?(Integer) && value.between?(0, maximum)
      end

      def unique_values?(entries, key)
        values = entries.pluck(key)
        values.uniq.size == values.size
      end

      def checksum(payload)
        Digest::SHA256.hexdigest(JSON.generate(deep_canonical_value(payload)))
      end

      def deep_canonical_value(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, deep_canonical_value(value.fetch(key)) ] }
        when Array
          value.map { |child| deep_canonical_value(child) }
        else
          value
        end
      end
    end
  end
end
