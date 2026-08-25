require "digest"
require "json"

module Receipts::Processing::Contracts
  class ItemCalculationModeProposalSet
    SCHEMA_VERSION = "item_calculation_mode_proposal_set_v1"
    CREATION_STAGE = "ocr_validation"
    SOURCE_PROVIDER = "azure_structured"
    PROVIDER_MODEL_ID = "prebuilt-receipt"
    PROVIDER_API_VERSION = "2024-11-30"
    SUPPORTED_STRING_INDEX_TYPES = Ocr::ResponseParser::AzureStringIndexMapper::SUPPORTED_INDEX_TYPES.freeze
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"

    MAX_SETS = 100
    MAX_OPTIONS = 2
    MAX_SERIALIZED_BYTES = 4_096
    MAX_TOTAL_SERIALIZED_BYTES = 128 * 1_024
    MAX_ID_BYTES = 160
    MAX_PATH_BYTES = 256
    MAX_EXACT_NUMBER_BYTES = 64
    MAX_PROVIDER_SPAN = 10_000_000
    MAX_ITEM_INDEX = MAX_SETS - 1
    MAX_NORMALIZED_NODES = 128
    MAX_NORMALIZED_DEPTH = 8
    MAX_NORMALIZED_COLLECTION_SIZE = 24
    MAX_NORMALIZED_STRING_BYTES = 512
    MAX_AMOUNT = BigDecimal("999999999999")
    MAX_QUANTITY = BigDecimal("9999")

    PRICING_SOURCE_KINDS = %w[count_unit_price explicit_line_total].freeze
    CONFLICTS = %w[count_semantics discount package reference_expression].freeze
    ROOT_REQUIRED_KEYS = %w[
      schema_version creation_stage candidate_id item_identity item_index source_provider
      provider_model_id provider_api_version string_index_type source_field_path
      provider_span_start provider_span_end destination_evidence conflicts options integrity_checksum
    ].freeze
    ROOT_OPTIONAL_KEYS = %w[printed_line_total].freeze
    ROOT_KEYS = (ROOT_REQUIRED_KEYS + ROOT_OPTIONAL_KEYS).freeze
    OPTION_KEYS = %w[proposal_id pricing_source_kind source evidence].freeze
    COUNT_SOURCE_KEYS = %w[price_amount quantity quantity_unit_code].freeze
    COUNT_EVIDENCE_KEYS = %w[price quantity quantity_unit].freeze
    EXPLICIT_SOURCE_KEYS = %w[line_total_amount].freeze
    EXPLICIT_EVIDENCE_KEYS = %w[line_total].freeze
    COMPONENT_KEYS = %w[amount evidence].freeze
    COMPONENT_EVIDENCE_KEYS = %w[
      source_field_path provider_span_start provider_span_end
    ].freeze
    INTEGRITY_CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    EXACT_INTEGER_PATTERN = /\A(?:0|[1-9][0-9]*)\z/.freeze
    CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze

    class << self
      def build_all(candidates:, ocr_snapshot:)
        context = ocr_context(ocr_snapshot)
        return nil if context.nil?
        return nil unless candidates.is_a?(Array) && candidates.size <= MAX_SETS

        proposals = candidates.map do |candidate|
          build_one(candidate, context: context)
        end
        return nil if proposals.any?(&:nil?)
        return nil unless collection_valid?(proposals, context: context)
        return nil unless total_serialized_within_bound?(proposals)

        proposals
      rescue ArgumentError, EncodingError, JSON::GeneratorError, TypeError
        nil
      end

      def from_snapshot(value, ocr_snapshot:)
        context = ocr_context(ocr_snapshot)
        return nil if context.nil?
        return nil unless value.is_a?(Array) && value.size <= MAX_SETS

        proposals = value.map do |proposal|
          normalized = bounded_normalized_hash(proposal)
          next if normalized.nil?
          next unless proposal_valid?(normalized, context: context)
          next unless integrity_valid?(normalized, context: context)

          normalized
        end
        return nil if proposals.any?(&:nil?)
        return nil unless collection_valid?(proposals, context: context)
        return nil unless total_serialized_within_bound?(proposals)

        deep_copy(proposals)
      rescue ArgumentError, EncodingError, JSON::GeneratorError, TypeError
        nil
      end

      private

      def build_one(value, context:)
        candidate = bounded_normalized_hash(value)
        return nil if candidate.nil?

        item_index = candidate["item_index"]
        return nil unless item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEM_INDEX)

        return nil unless context_item_matches?(candidate, context: context)

        proposal = {
          "schema_version" => SCHEMA_VERSION,
          "creation_stage" => CREATION_STAGE,
          "candidate_id" => candidate["candidate_id"],
          "item_identity" => candidate["item_identity"],
          "item_index" => item_index,
          "source_provider" => candidate["source_provider"],
          "provider_model_id" => candidate["provider_model_id"],
          "provider_api_version" => candidate["provider_api_version"],
          "string_index_type" => candidate["string_index_type"],
          "source_field_path" => candidate["source_field_path"],
          "provider_span_start" => candidate["provider_span_start"],
          "provider_span_end" => candidate["provider_span_end"],
          "destination_evidence" => candidate["destination_evidence"],
          "conflicts" => candidate["conflicts"],
          "options" => candidate["options"]
        }
        proposal["printed_line_total"] = candidate["printed_line_total"] if candidate["printed_line_total"]
        proposal["integrity_checksum"] = integrity_checksum(proposal, context: context)
        return nil unless proposal_valid?(proposal, context: context)
        return nil unless serialized_within_bound?(proposal)

        deep_copy(proposal)
      end

      def proposal_valid?(proposal, context:)
        return false unless root_keys_valid?(proposal)
        return false unless proposal["schema_version"] == SCHEMA_VERSION
        return false unless proposal["creation_stage"] == CREATION_STAGE
        return false unless proposal["source_provider"] == SOURCE_PROVIDER
        return false unless proposal["provider_model_id"] == PROVIDER_MODEL_ID
        return false unless proposal["provider_api_version"] == PROVIDER_API_VERSION
        return false unless SUPPORTED_STRING_INDEX_TYPES.include?(proposal["string_index_type"])
        return false unless bounded_string?(
          proposal["integrity_checksum"],
          maximum: 64,
          pattern: INTEGRITY_CHECKSUM_PATTERN
        )

        item_index = proposal["item_index"]
        return false unless item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEM_INDEX)

        parent_start = proposal["provider_span_start"]
        parent_end = proposal["provider_span_end"]
        return false unless valid_span?(parent_start, parent_end)
        return false unless bounded_string?(
          proposal["candidate_id"],
          maximum: MAX_ID_BYTES,
          pattern: /\Aazure_items_#{item_index}_item_calculation_mode\z/
        )
        return false unless bounded_string?(
          proposal["item_identity"],
          maximum: MAX_ID_BYTES,
          pattern: /\Aazure_structured_item_i#{item_index}_s#{parent_start}_e#{parent_end}\z/
        )
        return false unless proposal["source_field_path"] == "documents[0].fields.Items[#{item_index}]"
        return false unless proposal["source_field_path"].bytesize <= MAX_PATH_BYTES
        return false unless context_item_matches?(proposal, context: context)
        return false unless component_evidence_valid?(
          proposal["destination_evidence"],
          expected_path: "documents[0].fields.Items[#{item_index}].Description",
          parent_start: parent_start,
          parent_end: parent_end
        )
        return false unless conflicts_valid?(proposal["conflicts"])
        return false unless options_valid?(proposal, parent_start: parent_start, parent_end: parent_end)
        return false unless printed_line_total_valid?(
          proposal["printed_line_total"],
          item_index: item_index,
          parent_start: parent_start,
          parent_end: parent_end
        )
        return false unless printed_total_and_explicit_consistent?(proposal)
        return false unless serialized_within_bound?(proposal)

        true
      end

      def context_item_matches?(proposal, context:)
        matches = context.dig("candidates", "items").select do |item|
          item["ocr_item_identity"] == proposal["item_identity"]
        end

        matches.one? && context_item_source_matches?(proposal, matches.sole)
      end

      def context_item_source_matches?(proposal, item)
        options = proposal["options"]
        return false unless options.is_a?(Array)

        options.all? do |option|
          option = normalized_hash(option)
          source = normalized_hash(option["source"])

          case option["pricing_source_kind"]
          when "count_unit_price"
            context_integer_matches?(item["price"], source["price_amount"], maximum: MAX_AMOUNT, allow_zero: true) &&
              context_integer_matches?(item["quantity"], source["quantity"], maximum: MAX_QUANTITY, allow_zero: false) &&
              item["quantity_unit_code"] == source["quantity_unit_code"]
          when "explicit_line_total"
            context_integer_matches?(
              item["original_line_total"],
              source["line_total_amount"],
              maximum: MAX_AMOUNT,
              allow_zero: true
            )
          else
            false
          end
        end
      end

      def context_integer_matches?(value, exact, maximum:, allow_zero:)
        return false unless exact_integer?(exact, maximum: maximum, allow_zero: allow_zero)

        case value
        when Numeric
          decimal = BigDecimal(value.to_s)
          decimal.finite? && decimal.frac.zero? && decimal.to_i.to_s == exact
        when String
          bounded_string?(value, maximum: MAX_EXACT_NUMBER_BYTES, pattern: EXACT_INTEGER_PATTERN) &&
            value == exact
        else
          false
        end
      rescue ArgumentError
        false
      end

      def conflicts_valid?(value)
        value.is_a?(Array) &&
          value.uniq == value &&
          value.sort == value &&
          (value - CONFLICTS).empty?
      end

      def options_valid?(proposal, parent_start:, parent_end:)
        options = proposal["options"]
        return false unless options.is_a?(Array) && options.size.between?(1, MAX_OPTIONS)

        modes = options.map { |option| normalized_hash(option)["pricing_source_kind"] }
        expected_order = PRICING_SOURCE_KINDS.select { |kind| modes.include?(kind) }
        return false unless modes == expected_order && modes.uniq == modes
        return false if proposal["conflicts"].any? && modes.include?("count_unit_price")

        return false unless options.all? do |option|
          option_valid?(
            normalized_hash(option),
            item_index: proposal["item_index"],
            parent_start: parent_start,
            parent_end: parent_end
          )
        end

        all_evidence_nonoverlapping?(proposal)
      end

      def option_valid?(option, item_index:, parent_start:, parent_end:)
        return false unless exact_keys?(option, OPTION_KEYS)

        kind = option["pricing_source_kind"]
        return false unless PRICING_SOURCE_KINDS.include?(kind)
        return false unless option["proposal_id"] == "azure_items_#{item_index}_#{kind}"

        case kind
        when "count_unit_price"
          count_option_valid?(option, item_index: item_index, parent_start: parent_start, parent_end: parent_end)
        when "explicit_line_total"
          explicit_option_valid?(option, item_index: item_index, parent_start: parent_start, parent_end: parent_end)
        else
          false
        end
      end

      def count_option_valid?(option, item_index:, parent_start:, parent_end:)
        source = normalized_hash(option["source"])
        evidence = normalized_hash(option["evidence"])
        return false unless exact_keys?(source, COUNT_SOURCE_KEYS)
        return false unless exact_keys?(evidence, COUNT_EVIDENCE_KEYS)
        return false unless exact_integer?(source["price_amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return false unless exact_integer?(source["quantity"], maximum: MAX_QUANTITY, allow_zero: false)

        unit = ReceiptQuantityUnit.unit_for(source["quantity_unit_code"])
        return false unless unit&.code == source["quantity_unit_code"] && unit.kind == :countable

        {
          "price" => "Price",
          "quantity" => "Quantity",
          "quantity_unit" => "QuantityUnit"
        }.all? do |evidence_key, field_name|
          component_evidence_valid?(
            evidence[evidence_key],
            expected_path: "documents[0].fields.Items[#{item_index}].#{field_name}",
            parent_start: parent_start,
            parent_end: parent_end
          )
        end
      end

      def explicit_option_valid?(option, item_index:, parent_start:, parent_end:)
        source = normalized_hash(option["source"])
        evidence = normalized_hash(option["evidence"])
        return false unless exact_keys?(source, EXPLICIT_SOURCE_KEYS)
        return false unless exact_keys?(evidence, EXPLICIT_EVIDENCE_KEYS)
        return false unless exact_integer?(source["line_total_amount"], maximum: MAX_AMOUNT, allow_zero: true)

        component_evidence_valid?(
          evidence["line_total"],
          expected_path: "documents[0].fields.Items[#{item_index}].TotalPrice",
          parent_start: parent_start,
          parent_end: parent_end
        )
      end

      def printed_line_total_valid?(value, item_index:, parent_start:, parent_end:)
        return true if value.nil?

        component = normalized_hash(value)
        exact_keys?(component, COMPONENT_KEYS) &&
          exact_integer?(component["amount"], maximum: MAX_AMOUNT, allow_zero: true) &&
          component_evidence_valid?(
            component["evidence"],
            expected_path: "documents[0].fields.Items[#{item_index}].TotalPrice",
            parent_start: parent_start,
            parent_end: parent_end
          )
      end

      def printed_total_and_explicit_consistent?(proposal)
        explicit = proposal["options"].find do |option|
          normalized_hash(option)["pricing_source_kind"] == "explicit_line_total"
        end
        printed = normalized_hash(proposal["printed_line_total"])
        return explicit.nil? if printed.empty?
        return false if explicit.nil?

        explicit = normalized_hash(explicit)
        normalized_hash(explicit["source"])["line_total_amount"] == printed["amount"] &&
          normalized_hash(explicit["evidence"])["line_total"] == printed["evidence"]
      end

      def component_evidence_valid?(value, expected_path:, parent_start:, parent_end:)
        evidence = normalized_hash(value)
        return false unless exact_keys?(evidence, COMPONENT_EVIDENCE_KEYS)
        return false unless evidence["source_field_path"] == expected_path
        return false unless evidence["source_field_path"].bytesize <= MAX_PATH_BYTES

        start_value = evidence["provider_span_start"]
        end_value = evidence["provider_span_end"]
        valid_span?(start_value, end_value) &&
          start_value >= parent_start && end_value <= parent_end
      end

      def all_evidence_nonoverlapping?(proposal)
        evidence = [ proposal["destination_evidence"] ]
        proposal["options"].each do |option|
          normalized_hash(option["evidence"]).each_value { |entry| evidence << entry }
        end
        ranges = evidence.map { |entry| evidence_range(entry) }
        return false if ranges.any?(&:nil?)

        ranges.combination(2).none? do |left, right|
          left.begin < right.end && right.begin < left.end
        end
      end

      def evidence_range(value)
        evidence = normalized_hash(value)
        start_value = evidence["provider_span_start"]
        end_value = evidence["provider_span_end"]
        return unless valid_span?(start_value, end_value)

        (start_value...end_value)
      end

      def collection_valid?(proposals, context:)
        return false unless proposals.is_a?(Array) && proposals.size <= MAX_SETS

        candidate_ids = proposals.map { |proposal| proposal["candidate_id"] }
        item_identities = proposals.map { |proposal| proposal["item_identity"] }
        item_indexes = proposals.map { |proposal| proposal["item_index"] }

        counts = context.dig("candidate_counts", "item_calculation_mode_candidates")
        candidate_ids.uniq.size == candidate_ids.size &&
          item_identities.uniq.size == item_identities.size &&
          item_indexes.uniq.size == item_indexes.size &&
          item_indexes == item_indexes.sort &&
          counts["actual_count"] == proposals.size &&
          counts["snapshot_count"] == proposals.size
      end

      def ocr_context(value)
        return nil unless value.is_a?(Hash) && value.size <= 24

        source = bounded_context_hash(value)
        return nil if source.nil?
        return nil unless source["schema_version"] == OCR_RESULT_SCHEMA_VERSION
        return nil unless source["success"] == true

        truncated = bounded_context_hash(source["truncated"], maximum_entries: 24)
        return nil if truncated.nil?
        return nil unless truncated["items"] == false
        return nil unless truncated["item_calculation_mode_candidates"] == false

        candidate_counts = bounded_context_hash(source["candidate_counts"], maximum_entries: 24)
        return nil if candidate_counts.nil?
        item_counts = exact_count_metadata(candidate_counts["items"])
        proposal_counts = exact_count_metadata(candidate_counts["item_calculation_mode_candidates"])
        return nil if item_counts.nil? || proposal_counts.nil?

        candidates = bounded_context_hash(source["candidates"], maximum_entries: 32)
        return nil if candidates.nil?

        raw_items = candidates["items"]
        return nil unless raw_items.is_a?(Array) && raw_items.size <= 1_000
        return nil unless item_counts["actual_count"] == raw_items.size
        return nil unless item_counts["snapshot_count"] == raw_items.size

        items = raw_items.map do |item|
          item = bounded_context_hash(item, maximum_entries: 32)
          return nil if item.nil?

          identity = item["ocr_item_identity"]
          next {} if identity.nil?
          return nil unless bounded_string?(
            identity,
            maximum: MAX_ID_BYTES,
            pattern: /\Aazure_structured_item_i\d+_s\d+_e\d+\z/
          )

          {
            "ocr_item_identity" => identity,
            "price" => item["price"],
            "quantity" => item["quantity"],
            "quantity_unit_code" => item["quantity_unit_code"],
            "line_total" => item["line_total"],
            "original_line_total" => item["original_line_total"]
          }.compact
        end
        identities = items.filter_map { |item| item["ocr_item_identity"] }
        return nil unless identities.uniq.size == identities.size

        {
          "schema_version" => OCR_RESULT_SCHEMA_VERSION,
          "candidates" => { "items" => items },
          "candidate_counts" => {
            "item_calculation_mode_candidates" => proposal_counts
          }
        }
      end

      def bounded_context_hash(value, maximum_entries: 24)
        return unless value.is_a?(Hash) && value.size <= maximum_entries

        value.each_with_object({}) do |(key, entry), result|
          key = key.to_s
          return nil unless bounded_string?(key, maximum: MAX_NORMALIZED_STRING_BYTES)
          return nil if result.key?(key)

          result[key] = entry
        end
      end

      def exact_count_metadata(value)
        counts = bounded_context_hash(value, maximum_entries: 2)
        return unless counts&.keys&.sort == %w[actual_count snapshot_count]
        return unless counts.values.all? do |count|
          count.is_a?(Integer) && count.between?(0, MAX_SETS)
        end

        counts
      end

      def integrity_valid?(proposal, context:)
        actual = proposal["integrity_checksum"]
        expected = integrity_checksum(proposal, context: context)
        actual.is_a?(String) && expected.bytesize == actual.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(expected, actual)
      end

      def integrity_checksum(proposal, context:)
        payload = ROOT_KEYS.select do |key|
          key != "integrity_checksum" && proposal.key?(key)
        end.to_h do |key|
          [ key, proposal[key] ]
        end
        payload["ocr_binding"] = {
          "schema_version" => context["schema_version"],
          "item_identity" => proposal["item_identity"],
          "item_index" => proposal["item_index"]
        }

        Digest::SHA256.hexdigest(JSON.generate(deep_canonical_value(payload)))
      end

      def exact_integer?(value, maximum:, allow_zero:)
        return false unless bounded_string?(
          value,
          maximum: MAX_EXACT_NUMBER_BYTES,
          pattern: EXACT_INTEGER_PATTERN
        )

        decimal = BigDecimal(value)
        (allow_zero ? decimal >= 0 : decimal.positive?) && decimal <= maximum
      rescue ArgumentError
        false
      end

      def valid_span?(start_value, end_value)
        start_value.is_a?(Integer) && end_value.is_a?(Integer) &&
          start_value.between?(0, MAX_PROVIDER_SPAN) &&
          end_value.between?(1, MAX_PROVIDER_SPAN) &&
          end_value > start_value
      end

      def exact_keys?(value, keys)
        value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def root_keys_valid?(value)
        return false unless value.is_a?(Hash)

        keys = value.keys
        (ROOT_REQUIRED_KEYS - keys).empty? && (keys - ROOT_KEYS).empty?
      end

      def bounded_string?(value, maximum:, pattern: nil)
        value.is_a?(String) && value.bytesize <= maximum &&
          (value.encoding == Encoding::UTF_8 || value.encoding == Encoding::US_ASCII) &&
          value.valid_encoding? &&
          !value.match?(CONTROL_CHARACTER_PATTERN) && (pattern.nil? || value.match?(pattern))
      end

      def serialized_within_bound?(value)
        JSON.generate(value).bytesize <= MAX_SERIALIZED_BYTES
      end

      def total_serialized_within_bound?(value)
        JSON.generate(value).bytesize <= MAX_TOTAL_SERIALIZED_BYTES
      end

      def bounded_normalized_hash(
        value,
        maximum_nodes: MAX_NORMALIZED_NODES,
        maximum_collection_size: MAX_NORMALIZED_COLLECTION_SIZE
      )
        budget = { remaining: maximum_nodes }
        normalized = bounded_normalized_value(
          value,
          budget: budget,
          depth: 0,
          maximum_collection_size: maximum_collection_size
        )
        normalized if normalized.is_a?(Hash)
      end

      def bounded_normalized_value(value, budget:, depth:, maximum_collection_size:)
        return nil if depth > MAX_NORMALIZED_DEPTH

        budget[:remaining] -= 1
        return nil if budget[:remaining].negative?

        case value
        when Hash
          return nil if value.size > maximum_collection_size

          value.each_with_object({}) do |(key, entry), result|
            key = key.to_s
            return nil unless bounded_string?(key, maximum: MAX_NORMALIZED_STRING_BYTES)
            return nil if result.key?(key)

            normalized = bounded_normalized_value(
              entry,
              budget: budget,
              depth: depth + 1,
              maximum_collection_size: maximum_collection_size
            )
            return nil if normalized.nil? && !entry.nil?

            result[key] = normalized
          end
        when Array
          return nil if value.size > maximum_collection_size

          value.map do |entry|
            normalized = bounded_normalized_value(
              entry,
              budget: budget,
              depth: depth + 1,
              maximum_collection_size: maximum_collection_size
            )
            return nil if normalized.nil? && !entry.nil?

            normalized
          end
        when String
          return nil unless bounded_string?(value, maximum: MAX_NORMALIZED_STRING_BYTES)

          value.dup
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          nil
        end
      end

      def normalized_hash(value)
        value.is_a?(Hash) ? value.stringify_keys : {}
      end

      def deep_canonical_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            entry = value.key?(key) ? value[key] : value[key.to_sym]
            [ key, deep_canonical_value(entry) ]
          end
        when Array
          value.map { |entry| deep_canonical_value(entry) }
        else
          value
        end
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
