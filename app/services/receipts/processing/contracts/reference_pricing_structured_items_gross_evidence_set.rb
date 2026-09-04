require "bigdecimal"
require "digest"
require "json"

module Receipts::Processing::Contracts
  class ReferencePricingStructuredItemsGrossEvidenceSet
    SCHEMA_VERSION = "reference_pricing_structured_items_gross_evidence_set_v1"
    CREATION_STAGE = "ocr_validation"
    EVIDENCE_KIND = "structured_items_receipt_inner_tax_summary"
    MEMBER_EVIDENCE_KIND = "structured_items_receipt_inner_tax_summary_member"
    POLICY_CONTRACT_VERSION = "reference_pricing_structured_items_gross_policy_v1"
    SOURCE_PROVIDER = "azure_structured"
    SUMMARY_SOURCE_PROVIDER = "azure_document_total"
    PROVIDER_MODEL_ID = "prebuilt-receipt"
    PROVIDER_API_VERSION = "2024-11-30"
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"
    STRING_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze

    MAX_ITEMS = 20
    MAX_TAX_DETAILS = 20
    MAX_PARENT_SPANS = 16
    MAX_SERIALIZED_BYTES = 64 * 1_024
    MAX_PATH_BYTES = 256
    MAX_ID_BYTES = 128
    MAX_PROVIDER_SPAN = 10_000_000
    MAX_PAGE_INDEX = 7
    MAX_LINE_INDEX = 149
    MAX_AMOUNT = 999_999_999_999
    MAX_NORMALIZED_NODES = 4_096
    MAX_NORMALIZED_DEPTH = 8
    MAX_NORMALIZED_COLLECTION_SIZE = 32
    MAX_NORMALIZED_STRING_BYTES = 512

    CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    CANDIDATE_ID_PATTERN = /\Aazure_items_(?<item_index>0|[1-9]\d*)_reference_pricing\z/.freeze
    STRUCTURED_ITEM_IDENTITY_PATTERN = /\Aazure_structured_item_i(?<item_index>0|[1-9]\d*)_s\d+_e\d+\z/.freeze

    METADATA_KEYS = %w[
      kind string_index_type policy_contract_version candidate_members item_parents item_totals
      tax_detail_parents tax_descriptions tax_amounts summary_total
    ].freeze
    ROOT_KEYS = (%w[
      schema_version creation_stage source_provider provider_model_id provider_api_version
    ] + METADATA_KEYS + %w[integrity_checksum]).freeze
    MEMBER_KEYS = %w[candidate_id item_index].freeze
    PARENT_SPAN_KEYS = %w[provider_span_start provider_span_end].freeze
    ITEM_PARENT_KEYS = %w[source_provider source_field_path item_index provider_spans].freeze
    TAX_PARENT_KEYS = %w[source_provider source_field_path tax_detail_index provider_spans].freeze
    STRUCTURAL_KEYS = %w[
      source_provider source_field_path page_index line_index string_index_type
      provider_span_start provider_span_end
    ].freeze
    ITEM_TOTAL_KEYS = (STRUCTURAL_KEYS + %w[item_index amount]).freeze
    TAX_DESCRIPTION_KEYS = (STRUCTURAL_KEYS + %w[tax_detail_index]).freeze
    TAX_AMOUNT_KEYS = (TAX_DESCRIPTION_KEYS + %w[amount]).freeze
    SUMMARY_TOTAL_KEYS = (STRUCTURAL_KEYS + %w[amount]).freeze
    UNBOUND_MEMBER_HANDLE_KEYS = %w[kind policy_contract_version item_index].freeze
    MEMBER_HANDLE_KEYS = (UNBOUND_MEMBER_HANDLE_KEYS + %w[evidence_set_checksum]).freeze

    class << self
      def build(metadata:, ocr_snapshot:)
        metadata = bounded_normalized_hash(metadata)
        context = snapshot_context(ocr_snapshot, require_bound_members: false)
        return nil if metadata.nil? || context.nil?
        return nil unless exact_keys?(metadata, METADATA_KEYS)

        evidence_set = {
          "schema_version" => SCHEMA_VERSION,
          "creation_stage" => CREATION_STAGE,
          "source_provider" => SOURCE_PROVIDER,
          "provider_model_id" => PROVIDER_MODEL_ID,
          "provider_api_version" => PROVIDER_API_VERSION,
          **metadata
        }
        return nil unless evidence_set_valid?(evidence_set, context:)

        evidence_set["integrity_checksum"] = integrity_checksum(evidence_set, context:)
        return nil unless serialized_within_bound?(evidence_set)

        deep_copy(evidence_set)
      rescue ArgumentError, EncodingError, JSON::GeneratorError, KeyError, TypeError
        nil
      end

      def from_snapshot(value, ocr_snapshot:)
        evidence_set = bounded_normalized_hash(value)
        context = snapshot_context(ocr_snapshot, require_bound_members: true)
        return nil if evidence_set.nil? || context.nil?
        return nil unless exact_keys?(evidence_set, ROOT_KEYS)
        return nil unless evidence_set_valid?(evidence_set, context:)
        return nil unless serialized_within_bound?(evidence_set)
        return nil unless member_handles_bound?(context:, evidence_set:)
        return nil unless integrity_valid?(evidence_set, context:)

        deep_copy(evidence_set)
      rescue ArgumentError, EncodingError, JSON::GeneratorError, KeyError, TypeError
        nil
      end

      private

      def evidence_set_valid?(evidence_set, context:)
        return false unless evidence_set["schema_version"] == SCHEMA_VERSION
        return false unless evidence_set["creation_stage"] == CREATION_STAGE
        return false unless evidence_set["kind"] == EVIDENCE_KIND
        return false unless evidence_set["policy_contract_version"] == POLICY_CONTRACT_VERSION
        return false unless evidence_set["source_provider"] == SOURCE_PROVIDER
        return false unless evidence_set["provider_model_id"] == PROVIDER_MODEL_ID
        return false unless evidence_set["provider_api_version"] == PROVIDER_API_VERSION
        return false unless STRING_INDEX_TYPES.include?(evidence_set["string_index_type"])
        return false unless candidate_members_valid?(evidence_set["candidate_members"])
        return false unless item_evidence_valid?(evidence_set)
        return false unless tax_evidence_valid?(evidence_set)
        return false unless summary_total_valid?(evidence_set)
        return false unless aggregate_ranges_valid?(evidence_set)
        return false unless aggregate_amounts_valid?(evidence_set)
        return false unless context_matches?(evidence_set, context:)
        return false unless serialized_within_bound?(evidence_set)

        checksum = evidence_set["integrity_checksum"]
        checksum.nil? || bounded_string?(checksum, maximum: 64, pattern: CHECKSUM_PATTERN)
      end

      def candidate_members_valid?(value)
        return false unless value.is_a?(Array) && value.size.between?(2, MAX_ITEMS)

        members = value.each_with_index.map do |member, expected_index|
          return false unless exact_keys?(member, MEMBER_KEYS)

          item_index = member["item_index"]
          match = CANDIDATE_ID_PATTERN.match(member["candidate_id"].to_s)
          return false unless item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
          return false if match.nil? || Integer(match[:item_index], 10) != item_index
          return false unless bounded_string?(member["candidate_id"], maximum: MAX_ID_BYTES)
          return false if expected_index.positive? && item_index <= value.fetch(expected_index - 1)["item_index"].to_i

          member
        end
        members.pluck("candidate_id").uniq.size == members.size
      rescue ArgumentError
        false
      end

      def item_evidence_valid?(evidence_set)
        parents = evidence_set["item_parents"]
        totals = evidence_set["item_totals"]
        return false unless parents.is_a?(Array) && parents.size.between?(2, MAX_ITEMS)
        return false unless totals.is_a?(Array) && totals.size == parents.size

        parents.each_with_index.all? do |parent, item_index|
          parent_valid?(
            parent,
            expected_keys: ITEM_PARENT_KEYS,
            expected_path: "documents[0].fields.Items[#{item_index}]",
            index_key: "item_index",
            index: item_index
          ) && line_evidence_valid?(
            totals.fetch(item_index),
            expected_keys: ITEM_TOTAL_KEYS,
            expected_provider: SOURCE_PROVIDER,
            expected_path: "documents[0].fields.Items[#{item_index}].TotalPrice",
            index_type: evidence_set["string_index_type"],
            index_key: "item_index",
            index: item_index,
            amount: true
          ) && evidence_within_parent?(totals.fetch(item_index), parent)
        end && parent_groups_disjoint?(parents)
      end

      def tax_evidence_valid?(evidence_set)
        parents = evidence_set["tax_detail_parents"]
        descriptions = evidence_set["tax_descriptions"]
        amounts = evidence_set["tax_amounts"]
        return false unless parents.is_a?(Array) && parents.size.between?(1, MAX_TAX_DETAILS)
        return false unless descriptions.is_a?(Array) && descriptions.size == parents.size
        return false unless amounts.is_a?(Array) && amounts.size <= parents.size

        return false unless parents.each_with_index.all? do |parent, tax_detail_index|
          parent_valid?(
            parent,
            expected_keys: TAX_PARENT_KEYS,
            expected_path: "documents[0].fields.TaxDetails[#{tax_detail_index}]",
            index_key: "tax_detail_index",
            index: tax_detail_index
          ) && line_evidence_valid?(
            descriptions.fetch(tax_detail_index),
            expected_keys: TAX_DESCRIPTION_KEYS,
            expected_provider: SOURCE_PROVIDER,
            expected_path: "documents[0].fields.TaxDetails[#{tax_detail_index}].Description",
            index_type: evidence_set["string_index_type"],
            index_key: "tax_detail_index",
            index: tax_detail_index,
            amount: false
          ) && evidence_within_parent?(descriptions.fetch(tax_detail_index), parent)
        end
        return false unless parent_groups_disjoint?(parents)

        indexes = amounts.map { |entry| entry["tax_detail_index"] }
        return false unless indexes.uniq == indexes && indexes == indexes.sort

        amounts.all? do |entry|
          tax_detail_index = entry["tax_detail_index"]
          tax_detail_index.is_a?(Integer) && tax_detail_index.between?(0, parents.size - 1) &&
            line_evidence_valid?(
              entry,
              expected_keys: TAX_AMOUNT_KEYS,
              expected_provider: SOURCE_PROVIDER,
              expected_path: "documents[0].fields.TaxDetails[#{tax_detail_index}].Amount",
              index_type: evidence_set["string_index_type"],
              index_key: "tax_detail_index",
              index: tax_detail_index,
              amount: true
            ) && evidence_within_parent?(entry, parents.fetch(tax_detail_index)) &&
            !ranges_overlap?(entry, descriptions.fetch(tax_detail_index))
        end
      end

      def summary_total_valid?(evidence_set)
        summary = evidence_set["summary_total"]
        return false unless line_evidence_valid?(
          summary,
          expected_keys: SUMMARY_TOTAL_KEYS,
          expected_provider: SUMMARY_SOURCE_PROVIDER,
          expected_path: nil,
          index_type: evidence_set["string_index_type"],
          index_key: nil,
          index: nil,
          amount: true
        )

        summary["source_field_path"] == "pages[0].lines[#{summary['line_index']}]"
      end

      def parent_valid?(value, expected_keys:, expected_path:, index_key:, index:)
        return false unless exact_keys?(value, expected_keys)
        return false unless value["source_provider"] == SOURCE_PROVIDER
        return false unless value["source_field_path"] == expected_path
        return false unless value[index_key] == index

        spans = value["provider_spans"]
        spans.is_a?(Array) && spans.size.between?(1, MAX_PARENT_SPANS) &&
          spans.all? { |span| exact_keys?(span, PARENT_SPAN_KEYS) && bounded_span?(span) } &&
          spans.each_cons(2).all? do |left, right|
            left["provider_span_end"] <= right["provider_span_start"]
          end
      end

      def line_evidence_valid?(
        value,
        expected_keys:,
        expected_provider:,
        expected_path:,
        index_type:,
        index_key:,
        index:,
        amount:
      )
        return false unless exact_keys?(value, expected_keys)
        return false unless value["source_provider"] == expected_provider
        return false if expected_path && value["source_field_path"] != expected_path
        return false unless bounded_string?(value["source_field_path"], maximum: MAX_PATH_BYTES)
        return false unless value["page_index"].is_a?(Integer) && value["page_index"].between?(0, MAX_PAGE_INDEX)
        return false unless value["line_index"].is_a?(Integer) && value["line_index"].between?(0, MAX_LINE_INDEX)
        return false unless value["string_index_type"] == index_type
        return false unless bounded_span?(value)
        return false if index_key && value[index_key] != index
        return false if amount && !bounded_amount?(value["amount"])

        true
      end

      def aggregate_ranges_valid?(evidence_set)
        parents = evidence_set["item_parents"] + evidence_set["tax_detail_parents"]
        return false unless parent_groups_disjoint?(parents)

        summary = evidence_set["summary_total"]
        parents.none? { |parent| evidence_overlaps_parent?(summary, parent) }
      end

      def aggregate_amounts_valid?(evidence_set)
        evidence_set["item_totals"].sum { |entry| entry["amount"] } ==
          evidence_set.dig("summary_total", "amount")
      end

      def context_matches?(evidence_set, context:)
        return false unless evidence_set["item_parents"].size == context.fetch("items").size
        return false unless evidence_set["item_totals"].map { |entry| entry["amount"] } ==
          context.fetch("items").map { |item| item.fetch("line_total") }
        return false unless evidence_set.dig("summary_total", "amount") == context.fetch("total_amount")

        expected_members = context.fetch("reference_candidates").map do |candidate|
          {
            "candidate_id" => candidate.fetch("candidate_id"),
            "item_index" => candidate.fetch("item_index")
          }
        end
        evidence_set["candidate_members"] == expected_members
      end

      def snapshot_context(value, require_bound_members:)
        source = bounded_context_hash(value, maximum_entries: 32)
        return if source.nil? || source["schema_version"] != OCR_RESULT_SCHEMA_VERSION
        return unless source["success"] == true

        candidates = bounded_context_hash(source["candidates"], maximum_entries: 32)
        counts = bounded_context_hash(source["candidate_counts"], maximum_entries: 32)
        truncated = bounded_context_hash(source["truncated"], maximum_entries: 32)
        return if candidates.nil? || counts.nil? || truncated.nil?
        return unless truncated["items"] == false
        return unless truncated["reference_pricing_candidates"] == false

        raw_items = candidates["items"]
        item_counts = exact_count_metadata(counts["items"])
        return unless raw_items.is_a?(Array) && raw_items.size.between?(2, MAX_ITEMS)
        return unless item_counts == { "actual_count" => raw_items.size, "snapshot_count" => raw_items.size }

        items = raw_items.map.with_index do |item, item_index|
          item = bounded_context_hash(item, maximum_entries: 32)
          return if item.nil?

          identity = item["ocr_item_identity"]
          match = STRUCTURED_ITEM_IDENTITY_PATTERN.match(identity.to_s)
          line_total = canonical_amount(item["line_total"])
          return unless bounded_string?(identity, maximum: MAX_ID_BYTES)
          return if match.nil? || Integer(match[:item_index], 10) != item_index || line_total.nil?

          { "item_identity" => identity, "line_total" => line_total }
        end
        return if items.any?(&:nil?) || items.pluck("item_identity").uniq.size != items.size

        raw_references = candidates["reference_pricing_candidates"]
        reference_counts = exact_count_metadata(counts["reference_pricing_candidates"])
        return unless raw_references.is_a?(Array) && raw_references.size.between?(2, MAX_ITEMS)
        return unless reference_counts == {
          "actual_count" => raw_references.size,
          "snapshot_count" => raw_references.size
        }

        references = raw_references.map do |candidate|
          candidate = bounded_context_hash(candidate, maximum_entries: 32)
          return if candidate.nil?

          candidate_id = candidate["candidate_id"]
          item_index = candidate["item_index"]
          handle = bounded_context_hash(candidate["tax_inclusion_evidence"], maximum_entries: 4)
          expected_keys = require_bound_members ? MEMBER_HANDLE_KEYS : UNBOUND_MEMBER_HANDLE_KEYS
          return unless exact_keys?(handle, expected_keys) || (!require_bound_members && exact_keys?(handle, MEMBER_HANDLE_KEYS))
          return unless handle["kind"] == MEMBER_EVIDENCE_KIND
          return unless handle["policy_contract_version"] == POLICY_CONTRACT_VERSION
          return unless handle["item_index"] == item_index
          return unless candidate["validation_state"] == "valid"
          return unless candidate["rejection_reasons"] == []
          return unless candidate["reference_price_tax_inclusion"] == "gross"
          return unless bounded_string?(candidate_id, maximum: MAX_ID_BYTES, pattern: CANDIDATE_ID_PATTERN)
          return unless item_index.is_a?(Integer) && item_index.between?(0, items.size - 1)

          {
            "candidate_id" => candidate_id,
            "item_index" => item_index,
            "evidence_set_checksum" => handle["evidence_set_checksum"]
          }.compact
        end
        return if references.any?(&:nil?)
        return unless references.pluck("candidate_id").uniq.size == references.size
        return unless references.pluck("item_index").uniq.size == references.size

        total_amount = canonical_amount(candidates["total_amount"])
        return if total_amount.nil?

        {
          "schema_version" => OCR_RESULT_SCHEMA_VERSION,
          "items" => items,
          "reference_candidates" => references,
          "total_amount" => total_amount
        }
      rescue ArgumentError, EncodingError, TypeError
        nil
      end

      def member_handles_bound?(context:, evidence_set:)
        checksum = evidence_set["integrity_checksum"]
        context.fetch("reference_candidates").all? do |candidate|
          candidate["evidence_set_checksum"] == checksum
        end
      end

      def exact_count_metadata(value)
        counts = bounded_context_hash(value, maximum_entries: 2)
        return unless counts&.keys&.sort == %w[actual_count snapshot_count]
        return unless counts.values.all? do |count|
          count.is_a?(Integer) && count.between?(0, MAX_ITEMS)
        end

        counts
      end

      def evidence_within_parent?(evidence, parent)
        Array(parent["provider_spans"]).one? do |span|
          evidence["provider_span_start"] >= span["provider_span_start"] &&
            evidence["provider_span_end"] <= span["provider_span_end"]
        end
      end

      def evidence_overlaps_parent?(evidence, parent)
        Array(parent["provider_spans"]).any? { |span| ranges_overlap?(evidence, span) }
      end

      def parent_groups_disjoint?(parents)
        ranges = parents.flat_map.with_index do |parent, parent_index|
          Array(parent["provider_spans"]).map { |span| [ span, parent_index ] }
        end.sort_by { |span, _index| [ span["provider_span_start"], span["provider_span_end"] ] }
        ranges.each_cons(2).none? do |(left, left_index), (right, right_index)|
          left_index != right_index && ranges_overlap?(left, right)
        end
      end

      def ranges_overlap?(left, right)
        left["provider_span_start"] < right["provider_span_end"] &&
          right["provider_span_start"] < left["provider_span_end"]
      end

      def bounded_span?(value)
        start_offset = value["provider_span_start"]
        end_offset = value["provider_span_end"]
        start_offset.is_a?(Integer) && end_offset.is_a?(Integer) &&
          start_offset.between?(0, MAX_PROVIDER_SPAN) &&
          end_offset.between?(1, MAX_PROVIDER_SPAN) && end_offset > start_offset
      end

      def bounded_amount?(value)
        value.is_a?(Integer) && value.between?(0, MAX_AMOUNT)
      end

      def canonical_amount(value)
        return unless value.is_a?(Numeric) || bounded_string?(value, maximum: 64)
        return if value.respond_to?(:finite?) && !value.finite?

        amount = BigDecimal(value.to_s)
        return unless amount.frac.zero?

        integer = amount.to_i
        integer if integer.between?(0, MAX_AMOUNT)
      rescue ArgumentError
        nil
      end

      def integrity_valid?(evidence_set, context:)
        actual = evidence_set["integrity_checksum"]
        return false unless bounded_string?(actual, maximum: 64, pattern: CHECKSUM_PATTERN)

        expected = integrity_checksum(evidence_set, context:)
        ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      rescue ArgumentError, TypeError
        false
      end

      def integrity_checksum(evidence_set, context:)
        payload = {
          "evidence_set" => ROOT_KEYS.reject { |key| key == "integrity_checksum" }.to_h do |key|
            [ key, evidence_set[key] ]
          end,
          "ocr_context" => {
            "schema_version" => context.fetch("schema_version"),
            "items" => context.fetch("items"),
            "reference_candidates" => context.fetch("reference_candidates").map do |candidate|
              candidate.slice("candidate_id", "item_index")
            end,
            "total_amount" => context.fetch("total_amount")
          }
        }
        Digest::SHA256.hexdigest(JSON.generate(deep_canonical_value(payload)))
      end

      def exact_keys?(value, expected)
        value.is_a?(Hash) && value.keys.sort == expected.sort
      end

      def bounded_string?(value, maximum:, pattern: nil)
        value.is_a?(String) && value.valid_encoding? &&
          [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding) &&
          value.bytesize.between?(1, maximum) && !value.match?(CONTROL_CHARACTER_PATTERN) &&
          (pattern.nil? || value.match?(pattern))
      rescue ArgumentError, Encoding::CompatibilityError
        false
      end

      def serialized_within_bound?(value)
        JSON.generate(value).bytesize <= MAX_SERIALIZED_BYTES
      end

      def bounded_context_hash(value, maximum_entries: 24)
        return unless value.is_a?(Hash) && value.size <= maximum_entries

        value.each_with_object({}) do |(key, entry), result|
          return nil unless key.is_a?(String) || key.is_a?(Symbol)

          key = key.to_s
          return nil unless bounded_string?(key, maximum: 64)
          return nil if result.key?(key)

          result[key] = entry
        end
      end

      def bounded_normalized_hash(value)
        budget = { remaining: MAX_NORMALIZED_NODES }
        normalized = bounded_normalized_value(value, budget:, depth: 0)
        normalized if normalized.is_a?(Hash)
      rescue ArgumentError, EncodingError, SystemStackError, TypeError
        nil
      end

      def bounded_normalized_value(value, budget:, depth:)
        return nil if depth > MAX_NORMALIZED_DEPTH

        budget[:remaining] -= 1
        return nil if budget[:remaining].negative?

        case value
        when Hash
          return nil if value.size > MAX_NORMALIZED_COLLECTION_SIZE

          value.each_with_object({}) do |(key, entry), result|
            return nil unless key.is_a?(String) || key.is_a?(Symbol)

            normalized_key = key.to_s
            return nil unless bounded_string?(normalized_key, maximum: 64)
            return nil if result.key?(normalized_key)

            normalized = bounded_normalized_value(entry, budget:, depth: depth + 1)
            return nil if normalized.nil? && !entry.nil?

            result[normalized_key] = normalized
          end
        when Array
          return nil if value.size > MAX_NORMALIZED_COLLECTION_SIZE

          value.map do |entry|
            normalized = bounded_normalized_value(entry, budget:, depth: depth + 1)
            return nil if normalized.nil? && !entry.nil?

            normalized
          end
        when String
          value.dup if bounded_string?(value, maximum: MAX_NORMALIZED_STRING_BYTES)
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          nil
        end
      end

      def deep_canonical_value(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, deep_canonical_value(value[key]) ] }
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
