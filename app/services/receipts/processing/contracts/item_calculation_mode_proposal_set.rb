require "digest"
require "json"

module Receipts::Processing::Contracts
  class ItemCalculationModeProposalSet
    SCHEMA_VERSION = "item_calculation_mode_proposal_set_v1"
    CREATION_STAGE = "ocr_validation"
    SOURCE_PROVIDER = "azure_structured"
    LAYOUT_SOURCE_PROVIDER = "azure_item_layout"
    CALCULATION_LAYOUT_SOURCE_PROVIDER = "azure_calculation_layout"
    SOURCE_PROVIDERS = [ SOURCE_PROVIDER, LAYOUT_SOURCE_PROVIDER, CALCULATION_LAYOUT_SOURCE_PROVIDER ].freeze
    PROVIDER_MODEL_ID = "prebuilt-receipt"
    PROVIDER_API_VERSION = "2024-11-30"
    SUPPORTED_STRING_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
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
    MAX_LAYOUT_LINE_INDEX = 149
    MAX_NORMALIZED_NODES = 128
    MAX_REFERENCE_CANDIDATE_NODES = 192
    MAX_REFERENCE_CANDIDATE_COLLECTION_SIZE = 32
    MAX_NORMALIZED_DEPTH = 8
    MAX_NORMALIZED_COLLECTION_SIZE = 24
    MAX_NORMALIZED_STRING_BYTES = 512
    MAX_AMOUNT = BigDecimal("999999999999")
    MAX_QUANTITY = BigDecimal("9999")
    MAX_TAX_RATE_SCALE = 6
    MAX_DISCOUNT_RATE_SCALE = 3

    PRICING_SOURCE_KINDS = %w[
      count_unit_price
      reference_quantity_price
      explicit_line_total
    ].freeze
    CONFLICTS = %w[count_semantics discount package reference_expression].freeze
    ROOT_REQUIRED_KEYS = %w[
      schema_version creation_stage candidate_id item_identity item_index source_provider
      provider_model_id provider_api_version string_index_type source_field_path
      provider_span_start provider_span_end destination_evidence conflicts options integrity_checksum
    ].freeze
    ROOT_OPTIONAL_KEYS = %w[destination_kind printed_line_total].freeze
    ROOT_KEYS = (ROOT_REQUIRED_KEYS + ROOT_OPTIONAL_KEYS).freeze
    OPTION_KEYS = %w[proposal_id pricing_source_kind source evidence].freeze
    DISCOUNTED_OPTION_KEYS = (OPTION_KEYS + %w[discount]).freeze
    REFERENCE_OPTION_KEYS = (OPTION_KEYS + %w[source_candidate_id]).freeze
    COUNT_SOURCE_KEYS = %w[price_amount quantity quantity_unit_code].freeze
    COUNT_EVIDENCE_KEYS = %w[price quantity quantity_unit].freeze
    DISCOUNT_KEYS = %w[amount rate printed_total_stage evidence].freeze
    DISCOUNT_EVIDENCE_KEYS = %w[amount rate].freeze
    DISCOUNT_STAGES = %w[before_item_discount after_item_discount].freeze
    REFERENCE_SOURCE_KEYS = %w[
      reference_price_amount reference_quantity reference_quantity_unit_code
      reference_quantity_origin purchased_quantity purchased_quantity_unit_code
      reference_price_tax_inclusion
    ].freeze
    REFERENCE_EVIDENCE_KEYS = %w[
      reference_price reference_quantity purchased_quantity tax_inclusion
    ].freeze
    CALCULATION_LAYOUT_REFERENCE_EVIDENCE_KEYS = %w[
      reference_price reference_quantity reference_unit purchased_quantity purchased_unit tax_inclusion
    ].freeze
    EXPLICIT_SOURCE_KEYS = %w[line_total_amount].freeze
    EXPLICIT_EVIDENCE_KEYS = %w[line_total].freeze
    COMPONENT_KEYS = %w[amount evidence].freeze
    COMPONENT_EVIDENCE_KEYS = %w[
      source_field_path provider_span_start provider_span_end
    ].freeze
    INTEGRITY_CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    EXACT_INTEGER_PATTERN = /\A(?:0|[1-9][0-9]*)\z/.freeze
    EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9][0-9]*)(?:\.[0-9]*[1-9])?\z/.freeze
    REFERENCE_QUANTITY_ORIGINS = %w[explicit implicit_per_unit].freeze
    REFERENCE_TAX_INCLUSIONS = %w[gross net].freeze
    REFERENCE_UNIT_STATUSES = %w[known].freeze
    REFERENCE_CANDIDATE_REQUIRED_KEYS = %w[
      candidate_id item_index validation_state rejection_reasons reference_price
      reference_quantity purchased_quantity reference_price_tax_inclusion
      tax_inclusion_evidence
    ].freeze
    REFERENCE_CANDIDATE_OPTIONAL_KEYS = %w[printed_line_total corroboration].freeze
    REFERENCE_PRICE_COMPONENT_KEYS = %w[amount evidence].freeze
    REFERENCE_QUANTITY_COMPONENT_KEYS = %w[
      amount unit_code unit_status origin evidence
    ].freeze
    PURCHASED_QUANTITY_COMPONENT_KEYS = %w[amount unit_code unit_status evidence].freeze
    REFERENCE_CONTEXT_EVIDENCE_KEYS = %w[
      source_provider source_field_path item_index provider_span_start provider_span_end
    ].freeze
    REFERENCE_PRINTED_TOTAL_KEYS = %w[amount evidence].freeze
    REFERENCE_CORROBORATION_KEYS = %w[
      exact_amount projected_amount printed_line_total rounding_matches
    ].freeze
    REFERENCE_EXACT_AMOUNT_KEYS = %w[numerator denominator].freeze
    REFERENCE_ROUNDING_MATCHES = %w[floor half_up ceil].freeze
    LAYOUT_DESTINATION_KINDS = %w[azure_layout_item azure_structured_item].freeze
    HYBRID_LAYOUT_INPUT_KEYS = %w[
      candidate_id item_identity item_index source_provider provider_model_id provider_api_version
      string_index_type source_field_path provider_span_start provider_span_end destination_kind
      destination_evidence owned_line_indexes printed_line_total conflicts options
    ].freeze
    LAYOUT_REFERENCE_CANDIDATE_REQUIRED_KEYS = %w[
      candidate_id source_kind item_index item_identity destination_kind structured_item_index
      page_index name_line_index reference_line_index purchased_quantity_line_indexes
      reference_line_provider_span_start reference_line_provider_span_end
      printed_total_line_index owned_line_indexes string_index_type provider_model_id
      provider_api_version validation_contract_version block_provider_span_start
      block_provider_span_end validation_state rejection_reasons reference_price
      reference_quantity purchased_quantity reference_price_tax_inclusion tax_inclusion_evidence
      printed_line_total corroboration
    ].freeze
    LAYOUT_REFERENCE_CANDIDATE_OPTIONAL_KEYS = [].freeze
    LAYOUT_REFERENCE_CONTEXT_EVIDENCE_KEYS = %w[
      source_provider source_field_path page_index line_index string_index_type
      provider_span_start provider_span_end
    ].freeze
    SINGLE_ITEM_GROSS_SUMMARY_EVIDENCE_KIND = "single_item_receipt_gross_summary"
    SINGLE_ITEM_GROSS_SUMMARY_POLICY_VERSION = "reference_pricing_single_item_gross_summary_policy_v1"
    SINGLE_ITEM_GROSS_SUMMARY_EVIDENCE_KEYS = %w[
      kind string_index_type policy_contract_version summary_total gross_tax_target
    ].freeze
    SINGLE_ITEM_GROSS_SUMMARY_TOTAL_KEYS = (LAYOUT_REFERENCE_CONTEXT_EVIDENCE_KEYS + %w[amount]).freeze
    SINGLE_ITEM_GROSS_SUMMARY_TAX_KEYS = (LAYOUT_REFERENCE_CONTEXT_EVIDENCE_KEYS + %w[
      rate net_amount tax_amount gross_amount
    ]).freeze
    SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KIND = "single_item_receipt_inner_tax_summary"
    SINGLE_STRUCTURED_ITEM_GROSS_POLICY_VERSION = "reference_pricing_single_structured_item_gross_policy_v1"
    SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KEYS = %w[
      kind string_index_type policy_contract_version item_parent tax_detail_parent
      tax_description tax_amount document_tax_total summary_total
    ].freeze
    SINGLE_STRUCTURED_ITEM_GROSS_ITEM_PARENT_KEYS = %w[
      source_provider source_field_path item_index provider_span_start provider_span_end
    ].freeze
    SINGLE_STRUCTURED_ITEM_GROSS_TAX_PARENT_KEYS = %w[
      source_provider source_field_path tax_detail_index provider_span_start provider_span_end
    ].freeze
    SINGLE_STRUCTURED_ITEM_GROSS_LINE_KEYS = %w[
      source_provider source_field_path page_index line_index string_index_type
      provider_span_start provider_span_end
    ].freeze
    SINGLE_STRUCTURED_ITEM_GROSS_TAX_LINE_KEYS =
      (SINGLE_STRUCTURED_ITEM_GROSS_LINE_KEYS + %w[tax_detail_index]).freeze
    SINGLE_STRUCTURED_ITEM_GROSS_TAX_AMOUNT_KEYS =
      (SINGLE_STRUCTURED_ITEM_GROSS_TAX_LINE_KEYS + %w[amount]).freeze
    SINGLE_STRUCTURED_ITEM_GROSS_AMOUNT_KEYS =
      (SINGLE_STRUCTURED_ITEM_GROSS_LINE_KEYS + %w[amount]).freeze
    LAYOUT_PRODUCER_OFFSETS = [
      { reference: 1, reference_quantity: 1, purchased: [ 2 ], total: 3, owned: [ 0, 1, 2, 3 ] },
      { reference: 1, reference_quantity: 1, purchased: [ 3 ], total: 4, owned: [ 0, 1, 2, 3, 4 ] },
      { reference: 1, reference_quantity: 1, purchased: [ 2, 3 ], total: 4, owned: [ 0, 1, 2, 3, 4 ] },
      { reference: 2, reference_quantity: 2, purchased: [ 1 ], total: 3, owned: [ 0, 1, 2, 3 ] },
      { reference: 2, reference_quantity: 1, purchased: [ 3 ], total: 4, owned: [ 0, 1, 2, 3, 4 ] }
    ].freeze
    LAYOUT_ITEM_IDENTITY_PATTERN = /
      \Aazure_item_layout_item_p0_name_l(?<name>\d+)_s(?<name_start>\d+)_e(?<name_end>\d+)
      _ref_l(?<reference>\d+)_qty_l(?<quantity>\d+)_total_l(?<total>\d+)\z
    /x.freeze
    CALCULATION_LAYOUT_IDENTITY_PATTERN = /
      \Aazure_calculation_layout_p0_name_l(?<name_line_index>0|[1-9]\d*)
      _s(?<span_start>0|[1-9]\d*)_e(?<name_end>0|[1-9]\d*)_block_e(?<span_end>0|[1-9]\d*)\z
    /x.freeze
    STRUCTURED_ITEM_IDENTITY_PATTERN = /
      \Aazure_structured_item_i(?<item>\d+)_s(?<span_start>\d+)_e(?<span_end>\d+)\z
    /x.freeze
    LAYOUT_CANDIDATE_ID_PATTERN = /
      \Aazure_item_layout_p0_name_l(?<name>\d+)_ref_l(?<reference>\d+)
      _qty_l(?<quantity>\d+)_total_l(?<total>\d+)_item_calculation_mode\z
    /x.freeze
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

        return nil unless candidate["options"].is_a?(Array)
        return nil if layout_candidate?(candidate) && !layout_candidate_input_valid?(candidate)

        options = if layout_candidate?(candidate)
          layout_proposal_options(candidate)
        else
          candidate["options"].dup
        end
        reference_option = reference_option_for(candidate, context: context)
        options << reference_option if reference_option
        options = canonical_options(options)

        proposal = {
          "schema_version" => SCHEMA_VERSION,
          "creation_stage" => CREATION_STAGE,
          "candidate_id" => candidate["candidate_id"],
          "item_identity" => candidate["item_identity"],
          "item_index" => item_index,
          "source_provider" => candidate["source_provider"],
          "destination_kind" => candidate["destination_kind"],
          "provider_model_id" => candidate["provider_model_id"],
          "provider_api_version" => candidate["provider_api_version"],
          "string_index_type" => candidate["string_index_type"],
          "source_field_path" => candidate["source_field_path"],
          "provider_span_start" => candidate["provider_span_start"],
          "provider_span_end" => candidate["provider_span_end"],
          "destination_evidence" => stored_component_evidence(
            candidate["destination_evidence"],
            source_provider: candidate["source_provider"]
          ),
          "conflicts" => candidate["conflicts"],
          "options" => options
        }.compact
        if candidate["printed_line_total"]
          proposal["printed_line_total"] = stored_printed_line_total(
            candidate["printed_line_total"],
            source_provider: candidate["source_provider"]
          )
        end
        return nil unless context_item_matches?(proposal, context: context)

        proposal["integrity_checksum"] = integrity_checksum(proposal, context: context)
        return nil unless proposal_valid?(proposal, context: context)
        return nil unless serialized_within_bound?(proposal)

        deep_copy(proposal)
      end

      def canonical_options(value)
        options = Array(value).map { |option| bounded_normalized_hash(option) }
        return [] if options.any?(&:nil?)

        canonical = PRICING_SOURCE_KINDS.filter_map do |kind|
          matches = options.select { |option| option["pricing_source_kind"] == kind }
          return [] unless matches.size <= 1

          matches.sole if matches.one?
        end
        return [] unless canonical.size == options.size

        canonical
      end

      def reference_option_for(candidate, context:)
        return if calculation_layout_candidate?(candidate)
        return if layout_only_candidate?(candidate)
        return unless SUPPORTED_STRING_INDEX_TYPES.include?(candidate["string_index_type"])

        item_index = candidate["item_index"]
        expected_candidate_id = if hybrid_layout_candidate?(candidate)
          candidate["candidate_id"].sub(/_item_calculation_mode\z/, "_reference_pricing")
        else
          "azure_items_#{item_index}_reference_pricing"
        end
        matches = context.dig("candidates", "reference_pricing_candidates").select do |reference_candidate|
          reference_candidate["item_index"] == item_index &&
            reference_candidate["candidate_id"] == expected_candidate_id
        end
        return unless matches.one?

        reference_candidate = matches.sole
        return unless reference_candidate_valid?(
          reference_candidate,
          candidate: candidate,
          context: context
        )

        {
          "proposal_id" => expected_option_id(candidate, kind: "reference_quantity_price"),
          "pricing_source_kind" => "reference_quantity_price",
          "source_candidate_id" => reference_candidate["candidate_id"],
          "source" => {
            "reference_price_amount" => reference_candidate.dig("reference_price", "amount"),
            "reference_quantity" => reference_candidate.dig("reference_quantity", "amount"),
            "reference_quantity_unit_code" => reference_candidate.dig("reference_quantity", "unit_code"),
            "reference_quantity_origin" => reference_candidate.dig("reference_quantity", "origin"),
            "purchased_quantity" => reference_candidate.dig("purchased_quantity", "amount"),
            "purchased_quantity_unit_code" => reference_candidate.dig("purchased_quantity", "unit_code"),
            "reference_price_tax_inclusion" => reference_candidate["reference_price_tax_inclusion"]
          },
          "evidence" => {
            "reference_price" => proposal_evidence(reference_candidate.dig("reference_price", "evidence")),
            "reference_quantity" => proposal_evidence(reference_candidate.dig("reference_quantity", "evidence")),
            "purchased_quantity" => proposal_evidence(reference_candidate.dig("purchased_quantity", "evidence")),
            "tax_inclusion" => proposal_tax_inclusion_evidence(
              reference_candidate["tax_inclusion_evidence"]
            )
          }
        }
      end

      def proposal_tax_inclusion_evidence(value)
        evidence = normalized_hash(value)
        return deep_copy(evidence) if [
          SINGLE_ITEM_GROSS_SUMMARY_EVIDENCE_KIND,
          SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KIND
        ].include?(evidence["kind"])

        proposal_evidence(value)
      end

      def proposal_evidence(value)
        evidence = normalized_hash(value)
        COMPONENT_EVIDENCE_KEYS.to_h { |key| [ key, evidence[key] ] }
      end

      def stored_component_evidence(value, source_provider:)
        return value unless source_provider == LAYOUT_SOURCE_PROVIDER

        proposal_evidence(value)
      end

      def stored_printed_line_total(value, source_provider:)
        return value unless source_provider == LAYOUT_SOURCE_PROVIDER

        component = normalized_hash(value)
        {
          "amount" => component["amount"],
          "evidence" => proposal_evidence(component["evidence"])
        }
      end

      def layout_proposal_options(candidate)
        option = normalized_hash(candidate["options"].sole)
        evidence = normalized_hash(option["evidence"])
        [
          {
            "proposal_id" => option["proposal_id"],
            "pricing_source_kind" => option["pricing_source_kind"],
            "source" => normalized_hash(option["source"]),
            "evidence" => {
              "line_total" => proposal_evidence(evidence["line_total"])
            }
          }
        ]
      end

      def proposal_valid?(proposal, context:)
        return false unless root_keys_valid?(proposal)
        return false unless proposal["schema_version"] == SCHEMA_VERSION
        return false unless proposal["creation_stage"] == CREATION_STAGE
        return false unless SOURCE_PROVIDERS.include?(proposal["source_provider"])
        return false unless proposal["provider_model_id"] == PROVIDER_MODEL_ID
        return false unless proposal["provider_api_version"] == PROVIDER_API_VERSION
        return false unless SUPPORTED_STRING_INDEX_TYPES.include?(proposal["string_index_type"])
        return false unless destination_kind_valid?(proposal)
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
        return false unless proposal_identity_valid?(
          proposal,
          item_index: item_index,
          parent_start: parent_start,
          parent_end: parent_end
        )
        return false unless proposal["source_field_path"].bytesize <= MAX_PATH_BYTES
        return false unless context_item_matches?(proposal, context: context)
        return false unless reference_options_match_context?(proposal, context: context)
        return false unless destination_evidence_valid?(
          proposal,
          parent_start: parent_start,
          parent_end: parent_end
        )
        return false unless conflicts_valid?(proposal["conflicts"])
        return false unless options_valid?(proposal, parent_start: parent_start, parent_end: parent_end)
        return false unless printed_line_total_valid?(
          proposal["printed_line_total"],
          proposal: proposal,
          parent_start: parent_start,
          parent_end: parent_end
        )
        return false unless printed_total_and_explicit_consistent?(proposal)
        return false unless serialized_within_bound?(proposal)

        true
      end

      def destination_kind_valid?(proposal)
        case proposal["source_provider"]
        when SOURCE_PROVIDER
          !proposal.key?("destination_kind")
        when CALCULATION_LAYOUT_SOURCE_PROVIDER
          !proposal.key?("destination_kind")
        when LAYOUT_SOURCE_PROVIDER
          if proposal["item_identity"].to_s.match?(LAYOUT_ITEM_IDENTITY_PATTERN)
            proposal["destination_kind"] == "azure_layout_item"
          elsif proposal["item_identity"].to_s.match?(STRUCTURED_ITEM_IDENTITY_PATTERN)
            proposal["destination_kind"] == "azure_structured_item"
          else
            false
          end
        else
          false
        end
      end

      def proposal_identity_valid?(proposal, item_index:, parent_start:, parent_end:)
        return calculation_layout_identity_valid?(proposal) if calculation_layout_candidate?(proposal)

        if hybrid_layout_candidate?(proposal)
          metadata = layout_candidate_metadata(proposal)
          identity = structured_item_identity_metadata(proposal["item_identity"])
          metadata.present? && identity.present? &&
            proposal["destination_kind"] == "azure_structured_item" &&
            identity.fetch(:item_index) == item_index &&
            proposal["source_field_path"] == layout_line_path(metadata.fetch(:name_line_index))
        elsif layout_candidate?(proposal)
          metadata = layout_identity_metadata(proposal)
          metadata.present? &&
            proposal["source_field_path"] == layout_line_path(metadata.fetch(:name_line_index)) &&
            metadata.fetch(:name_span_start) >= parent_start &&
            metadata.fetch(:name_span_end) <= parent_end
        else
          bounded_string?(
            proposal["candidate_id"],
            maximum: MAX_ID_BYTES,
            pattern: /\Aazure_items_#{item_index}_item_calculation_mode\z/
          ) &&
            bounded_string?(
              proposal["item_identity"],
              maximum: MAX_ID_BYTES,
              pattern: /\Aazure_structured_item_i#{item_index}_s#{parent_start}_e#{parent_end}\z/
            ) &&
            proposal["source_field_path"] == "documents[0].fields.Items[#{item_index}]"
        end
      end

      def destination_evidence_valid?(proposal, parent_start:, parent_end:)
        if calculation_layout_candidate?(proposal)
          return component_evidence_valid?(
            proposal["destination_evidence"],
            expected_path: proposal["source_field_path"],
            parent_start: parent_start,
            parent_end: parent_end
          )
        end

        if layout_candidate?(proposal)
          metadata = if hybrid_layout_candidate?(proposal)
            layout_candidate_metadata(proposal)
          else
            layout_identity_metadata(proposal)
          end
          return false if metadata.nil?

          evidence = normalized_hash(proposal["destination_evidence"])
          valid = component_evidence_valid?(
            evidence,
            expected_path: layout_line_path(metadata.fetch(:name_line_index)),
            parent_start: parent_start,
            parent_end: parent_end
          )
          return false unless valid

          if hybrid_layout_candidate?(proposal)
            identity = structured_item_identity_metadata(proposal["item_identity"])
            identity.present? &&
              evidence["provider_span_start"] >= identity.fetch(:span_start) &&
              evidence["provider_span_end"] <= identity.fetch(:span_end)
          else
            evidence["provider_span_start"] == metadata.fetch(:name_span_start) &&
              evidence["provider_span_end"] == metadata.fetch(:name_span_end)
          end
        else
          component_evidence_valid?(
            proposal["destination_evidence"],
            expected_path: "documents[0].fields.Items[#{proposal['item_index']}].Description",
            parent_start: parent_start,
            parent_end: parent_end
          )
        end
      end

      def layout_candidate?(value)
        value["source_provider"] == LAYOUT_SOURCE_PROVIDER
      end

      def hybrid_layout_candidate?(value)
        layout_candidate?(value) &&
          value["destination_kind"] == "azure_structured_item" &&
          value["item_identity"].to_s.match?(STRUCTURED_ITEM_IDENTITY_PATTERN)
      end

      def layout_only_candidate?(value)
        layout_candidate?(value) && !hybrid_layout_candidate?(value)
      end

      def layout_candidate_input_valid?(candidate)
        hybrid = hybrid_layout_candidate?(candidate)
        return false if hybrid && !exact_keys?(candidate, HYBRID_LAYOUT_INPUT_KEYS)

        metadata = hybrid ? layout_candidate_metadata(candidate) : layout_identity_metadata(candidate)
        identity = structured_item_identity_metadata(candidate["item_identity"]) if hybrid
        return false if metadata.nil? || (hybrid && identity.nil?)

        parent_start = candidate["provider_span_start"]
        parent_end = candidate["provider_span_end"]
        return false unless valid_span?(parent_start, parent_end)
        return false unless candidate["source_field_path"] == layout_line_path(metadata.fetch(:name_line_index))
        return false unless candidate["conflicts"] == []
        if hybrid
          return false unless candidate["item_index"] == identity.fetch(:item_index)
          return false unless exact_owned_line_indexes?(candidate["owned_line_indexes"], metadata:)
        end
        return false unless layout_source_evidence_valid?(
          candidate["destination_evidence"],
          source_field_path: layout_line_path(metadata.fetch(:name_line_index)),
          span_start: metadata[:name_span_start],
          span_end: metadata[:name_span_end],
          candidate: candidate,
          parent_start: parent_start,
          parent_end: parent_end
        )

        layout_explicit_input_valid?(candidate, metadata:, parent_start:, parent_end:)
      end

      def layout_explicit_input_valid?(candidate, metadata:, parent_start:, parent_end:)
        printed = normalized_hash(candidate["printed_line_total"])
        return false unless exact_integer?(printed["amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return false unless layout_source_evidence_valid?(
          printed["evidence"],
          source_field_path: layout_line_path(metadata.fetch(:total_line_index)),
          candidate: candidate,
          parent_start: parent_start,
          parent_end: parent_end
        )

        option = Array(candidate["options"]).sole if Array(candidate["options"]).one?
        option = normalized_hash(option)
        source = normalized_hash(option["source"])
        evidence = normalized_hash(option["evidence"])
        exact_keys?(option, OPTION_KEYS) &&
          exact_keys?(source, EXPLICIT_SOURCE_KEYS) &&
          exact_keys?(evidence, EXPLICIT_EVIDENCE_KEYS) &&
          option["pricing_source_kind"] == "explicit_line_total" &&
          option["proposal_id"] == expected_option_id(candidate, kind: "explicit_line_total") &&
          source["line_total_amount"] == printed["amount"] &&
          normalized_hash(evidence["line_total"]) == normalized_hash(printed["evidence"])
      end

      def exact_owned_line_indexes?(value, metadata:)
        indexes = value
        return false unless indexes.is_a?(Array) && indexes.size.between?(1, 6)
        return false unless indexes.uniq == indexes && indexes.sort == indexes
        return false unless indexes.all? do |index|
          index.is_a?(Integer) && index.between?(0, MAX_LAYOUT_LINE_INDEX)
        end

        layout_producer_contracts(metadata).any? do |contract|
          indexes == producer_line_indexes(metadata, contract.fetch(:owned))
        end
      end

      def layout_identity_metadata(candidate)
        item_identity = candidate["item_identity"]
        return unless bounded_string?(item_identity, maximum: MAX_ID_BYTES)

        match = LAYOUT_ITEM_IDENTITY_PATTERN.match(item_identity)
        return if match.nil?

        identity_metadata = {
          name_line_index: Integer(match[:name], 10),
          name_span_start: Integer(match[:name_start], 10),
          name_span_end: Integer(match[:name_end], 10),
          reference_line_index: Integer(match[:reference], 10),
          quantity_line_index: Integer(match[:quantity], 10),
          total_line_index: Integer(match[:total], 10)
        }
        return unless identity_metadata.values_at(:name_line_index, :reference_line_index, :quantity_line_index, :total_line_index)
          .all? { |index| index.between?(0, MAX_LAYOUT_LINE_INDEX) }
        return unless valid_span?(
          identity_metadata.fetch(:name_span_start),
          identity_metadata.fetch(:name_span_end)
        )

        candidate_metadata = layout_candidate_metadata(candidate)
        return if candidate_metadata.nil?
        compared_keys = %i[name_line_index reference_line_index quantity_line_index total_line_index]
        return unless candidate_metadata.slice(*compared_keys) == identity_metadata.slice(*compared_keys)

        identity_metadata
      rescue ArgumentError
        nil
      end

      def layout_candidate_metadata(candidate)
        candidate_id = candidate["candidate_id"]
        return unless bounded_string?(candidate_id, maximum: MAX_ID_BYTES)

        match = LAYOUT_CANDIDATE_ID_PATTERN.match(candidate_id)
        return if match.nil?

        metadata = {
          name_line_index: Integer(match[:name], 10),
          reference_line_index: Integer(match[:reference], 10),
          quantity_line_index: Integer(match[:quantity], 10),
          total_line_index: Integer(match[:total], 10)
        }
        indexes = metadata.values
        return unless indexes.all? { |index| index.between?(0, MAX_LAYOUT_LINE_INDEX) }
        return if layout_producer_contracts(metadata).empty?

        metadata
      rescue ArgumentError
        nil
      end

      def layout_producer_contracts(metadata)
        name_line_index = metadata.fetch(:name_line_index)
        LAYOUT_PRODUCER_OFFSETS.select do |contract|
          metadata.fetch(:reference_line_index) == name_line_index + contract.fetch(:reference) &&
            metadata.fetch(:quantity_line_index) == name_line_index + contract.fetch(:purchased).last &&
            metadata.fetch(:total_line_index) == name_line_index + contract.fetch(:total)
        end
      end

      def producer_line_indexes(metadata, offsets)
        name_line_index = metadata.fetch(:name_line_index)
        offsets.map { |offset| name_line_index + offset }
      end

      def exact_layout_producer_contract(reference_candidate, metadata:)
        reference_quantity_line_index = layout_line_index(
          normalized_hash(reference_candidate.dig("reference_quantity", "evidence"))["source_field_path"]
        )
        matches = layout_producer_contracts(metadata).select do |contract|
          reference_candidate["owned_line_indexes"] == producer_line_indexes(metadata, contract.fetch(:owned)) &&
            reference_candidate["purchased_quantity_line_indexes"] ==
              producer_line_indexes(metadata, contract.fetch(:purchased)) &&
            reference_quantity_line_index ==
              metadata.fetch(:name_line_index) + contract.fetch(:reference_quantity)
        end
        matches.sole if matches.one?
      end

      def expected_reference_quantity_line_index(metadata)
        contracts = layout_producer_contracts(metadata)
        line_indexes = contracts.map do |contract|
          metadata.fetch(:name_line_index) + contract.fetch(:reference_quantity)
        end.uniq
        line_indexes.sole if line_indexes.one?
      end

      def structured_item_identity_metadata(value)
        return unless bounded_string?(value, maximum: MAX_ID_BYTES)

        match = STRUCTURED_ITEM_IDENTITY_PATTERN.match(value)
        return if match.nil?

        item_index = Integer(match[:item], 10)
        span_start = Integer(match[:span_start], 10)
        span_end = Integer(match[:span_end], 10)
        return unless item_index.between?(0, MAX_ITEM_INDEX) && valid_span?(span_start, span_end)

        { item_index: item_index, span_start: span_start, span_end: span_end }
      rescue ArgumentError
        nil
      end

      def layout_source_evidence_valid?(
        value,
        source_field_path:,
        candidate:,
        parent_start:,
        parent_end:,
        span_start: nil,
        span_end: nil
      )
        evidence = normalized_hash(value)
        return false unless evidence["source_provider"] == LAYOUT_SOURCE_PROVIDER
        return false unless evidence["source_field_path"] == source_field_path
        return false unless evidence["string_index_type"] == candidate["string_index_type"]

        start_value = evidence["provider_span_start"]
        end_value = evidence["provider_span_end"]
        valid_span?(start_value, end_value) && start_value >= parent_start && end_value <= parent_end &&
          (span_start.nil? || start_value == span_start) && (span_end.nil? || end_value == span_end)
      end

      def layout_line_path(line_index)
        "pages[0].lines[#{line_index}]"
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
              item["quantity_unit_code"] == source["quantity_unit_code"] &&
              count_discount_matches_context?(option, item)
          when "reference_quantity_price"
            context_decimal_matches?(
              item["price"],
              source["reference_price_amount"],
              maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX,
              maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
              allow_zero: true
            ) &&
              context_decimal_matches?(
                item["quantity"],
                source["purchased_quantity"],
                maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
                maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
                allow_zero: false
              ) &&
              item["quantity_unit_code"] == source["purchased_quantity_unit_code"]
          when "explicit_line_total"
            if option.key?("discount")
              next context_integer_matches?(item["original_line_total"], source["line_total_amount"], maximum: MAX_AMOUNT, allow_zero: true) &&
                discount_matches_context?(option, item, projection: explicit_discount_projection(option))
            end
            discounted_count = options.any? do |entry|
              entry["pricing_source_kind"] == "count_unit_price" && entry.key?("discount")
            end
            context_integer_matches?(
              item[discounted_count ? "line_total" : "original_line_total"],
              source["line_total_amount"],
              maximum: MAX_AMOUNT,
              allow_zero: true
            )
          else
            false
          end
        end
      end

      def count_discount_matches_context?(option, item)
        return true unless option.key?("discount")

        discount_matches_context?(option, item, projection: count_discount_projection(option))
      end

      def discount_matches_context?(option, item, projection:)
        discount = normalized_hash(option["discount"])
        return false unless projection
        return false unless context_integer_matches?(item["discount_amount"], discount["amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return false unless context_decimal_matches?(
          item["discount_rate"],
          discount["rate"],
          maximum: 1,
          maximum_scale: MAX_DISCOUNT_RATE_SCALE,
          allow_zero: false
        )

        context_integer_matches?(item["original_line_total"], projection[:original_line_total].to_s, maximum: MAX_AMOUNT, allow_zero: true) &&
          context_integer_matches?(item["line_total"], projection[:projected_amount].to_s, maximum: MAX_AMOUNT, allow_zero: true)
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

      def context_decimal_matches?(value, exact, maximum:, maximum_scale:, allow_zero:)
        return false unless exact_decimal?(
          exact,
          maximum: maximum,
          maximum_scale: maximum_scale,
          allow_zero: allow_zero
        )

        case value
        when Numeric
          decimal = BigDecimal(value.to_s)
          decimal.finite? && canonical_decimal_string(decimal) == exact
        when String
          value == exact
        else
          false
        end
      rescue ArgumentError
        false
      end

      def calculation_layout_candidate?(value)
        value["source_provider"] == CALCULATION_LAYOUT_SOURCE_PROVIDER
      end

      def calculation_layout_identity_metadata(value)
        return unless value.is_a?(String) && value.bytesize <= MAX_ID_BYTES

        match = CALCULATION_LAYOUT_IDENTITY_PATTERN.match(value)
        return if match.nil?

        metadata = {
          name_line_index: Integer(match[:name_line_index], 10),
          span_start: Integer(match[:span_start], 10),
          name_end: Integer(match[:name_end], 10),
          span_end: Integer(match[:span_end], 10)
        }
        return unless metadata[:name_line_index].between?(0, MAX_LAYOUT_LINE_INDEX)
        return unless valid_span?(metadata[:span_start], metadata[:name_end])
        return unless valid_span?(metadata[:name_end], metadata[:span_end])

        metadata
      end

      def calculation_layout_identity_valid?(proposal)
        metadata = calculation_layout_identity_metadata(proposal["item_identity"])
        return false if metadata.nil?
        return false unless bounded_string?(proposal["candidate_id"], maximum: MAX_ID_BYTES)
        return false unless proposal["candidate_id"] == "#{proposal['item_identity']}_item_calculation_mode"
        return false unless proposal["source_field_path"] == layout_line_path(metadata[:name_line_index])
        return false unless proposal["provider_span_start"] == metadata[:span_start]
        return false unless proposal["provider_span_end"] == metadata[:span_end]

        destination = normalized_hash(proposal["destination_evidence"])
        destination["provider_span_start"] == metadata[:span_start] &&
          destination["provider_span_end"] == metadata[:name_end]
      end

      def calculation_layout_options_valid?(proposal)
        options = proposal["options"]
        return false unless proposal["conflicts"] == []
        return false unless options.is_a?(Array) && options.size.between?(1, MAX_OPTIONS)

        modes = options.map { |option| normalized_hash(option)["pricing_source_kind"] }
        return false unless [
          %w[explicit_line_total],
          %w[count_unit_price explicit_line_total],
          %w[reference_quantity_price explicit_line_total]
        ].include?(modes)
        return false unless proposal["printed_line_total"].is_a?(Hash)

        count_offsets = calculation_layout_count_offsets(proposal) if modes.include?("count_unit_price")
        return false if modes.include?("count_unit_price") && count_offsets.nil?

        valid = options.all? do |option|
          return false unless exact_keys?(option, OPTION_KEYS)
          return false unless bounded_string?(option["proposal_id"], maximum: MAX_ID_BYTES)
          return false unless option["proposal_id"] == "#{proposal['item_identity']}_#{option['pricing_source_kind']}"

          source = normalized_hash(option["source"])
          evidence = normalized_hash(option["evidence"])
          case option["pricing_source_kind"]
          when "count_unit_price"
            unit = ReceiptQuantityUnit.unit_for(source["quantity_unit_code"])
            exact_keys?(source, COUNT_SOURCE_KEYS) &&
              exact_keys?(evidence, COUNT_EVIDENCE_KEYS) &&
              exact_integer?(source["price_amount"], maximum: MAX_AMOUNT, allow_zero: true) &&
              exact_integer?(source["quantity"], maximum: MAX_QUANTITY, allow_zero: false) &&
              unit&.code == source["quantity_unit_code"] && unit.kind == :countable &&
              calculation_layout_evidence_valid?(evidence, proposal: proposal, offsets: count_offsets.except("line_total"))
          when "reference_quantity_price"
            exact_keys?(source, REFERENCE_SOURCE_KEYS) &&
              exact_keys?(evidence, CALCULATION_LAYOUT_REFERENCE_EVIDENCE_KEYS) &&
              source["reference_quantity_origin"] == "explicit" &&
              reference_source_valid?(source) &&
              reference_projection(source).present? &&
              calculation_layout_evidence_valid?(
                evidence,
                proposal: proposal,
                offsets: {
                  "reference_price" => 1,
                  "reference_quantity" => 1,
                  "reference_unit" => 1,
                  "tax_inclusion" => 1,
                  "purchased_quantity" => 2,
                  "purchased_unit" => 2
                }
              )
          when "explicit_line_total"
            total_offset = if count_offsets
              count_offsets.fetch("line_total")
            elsif modes.one?
              nil
            else
              3
            end
            exact_keys?(source, EXPLICIT_SOURCE_KEYS) &&
              exact_keys?(evidence, EXPLICIT_EVIDENCE_KEYS) &&
              exact_integer?(source["line_total_amount"], maximum: MAX_AMOUNT, allow_zero: true) &&
              calculation_layout_evidence_valid?(evidence, proposal: proposal, offsets: { "line_total" => total_offset })
          end
        end
        valid && all_evidence_nonoverlapping?(proposal) && calculation_layout_evidence_order_valid?(proposal)
      end

      def calculation_layout_evidence_order_valid?(proposal)
        evidence = [ proposal["destination_evidence"] ]
        proposal["options"].each do |option|
          components = option["evidence"]
          quantity, unit = if option["pricing_source_kind"] == "count_unit_price"
            components.values_at("quantity", "quantity_unit")
          elsif option["pricing_source_kind"] == "reference_quantity_price"
            return false if components["reference_quantity"]["provider_span_end"] > components["reference_unit"]["provider_span_start"]

            components.values_at("purchased_quantity", "purchased_unit")
          end
          return false if quantity && quantity["provider_span_end"] > unit["provider_span_start"]

          evidence.concat(components.values)
        end
        lines = evidence.group_by do |component|
          Integer(component["source_field_path"][/\[(\d+)\]\z/, 1], 10)
        end.sort_by(&:first)
        lines.each_cons(2).all? do |(_, previous), (_, following)|
          previous.map { |component| component["provider_span_end"] }.max <=
            following.map { |component| component["provider_span_start"] }.min
        end
      end

      def calculation_layout_count_offsets(proposal)
        metadata = calculation_layout_identity_metadata(proposal["item_identity"])
        count = normalized_hash(proposal["options"].find { |option| option["pricing_source_kind"] == "count_unit_price" })
        explicit = normalized_hash(proposal["options"].find { |option| option["pricing_source_kind"] == "explicit_line_total" })
        evidence = normalized_hash(count["evidence"]).merge(normalized_hash(explicit["evidence"]))
        roles = %w[price quantity quantity_unit line_total]
        paths = roles.map { |role| normalized_hash(evidence[role])["source_field_path"] }
        offsets = [ [ 1, 2, 2, 3 ], [ 2, 4, 4, 5 ] ].find do |tuple|
          paths == tuple.map { |offset| layout_line_path(metadata[:name_line_index] + offset) }
        end

        roles.zip(offsets).to_h if offsets
      end

      def calculation_layout_evidence_valid?(evidence, proposal:, offsets:)
        metadata = calculation_layout_identity_metadata(proposal["item_identity"])
        return false if metadata.nil?

        offsets.all? do |role, offset|
          component = normalized_hash(evidence[role])
          match = /\Apages\[0\]\.lines\[(0|[1-9]\d*)\]\z/.match(component["source_field_path"].to_s)
          next false if match.nil?

          index = Integer(match[1], 10)
          valid_line = offset ? index == metadata[:name_line_index] + offset : index.between?(metadata[:name_line_index] + 1, metadata[:name_line_index] + 2)
          valid_line && index <= MAX_LAYOUT_LINE_INDEX &&
            component_evidence_valid?(
              component,
              expected_path: layout_line_path(index),
              parent_start: metadata[:span_start],
              parent_end: metadata[:span_end]
            )
        end
      end

      def conflicts_valid?(value)
        value.is_a?(Array) &&
          value.uniq == value &&
          value.sort == value &&
          (value - CONFLICTS).empty?
      end

      def options_valid?(proposal, parent_start:, parent_end:)
        return calculation_layout_options_valid?(proposal) if calculation_layout_candidate?(proposal)

        options = proposal["options"]
        return false unless options.is_a?(Array) && options.size.between?(1, MAX_OPTIONS)

        modes = options.map { |option| normalized_hash(option)["pricing_source_kind"] }
        expected_order = PRICING_SOURCE_KINDS.select { |kind| modes.include?(kind) }
        return false unless modes == expected_order && modes.uniq == modes
        if layout_only_candidate?(proposal)
          return false unless modes == [ "explicit_line_total" ] && proposal["conflicts"] == []
        elsif hybrid_layout_candidate?(proposal)
          return false unless modes == %w[reference_quantity_price explicit_line_total]
          return false unless proposal["conflicts"] == []
        end
        unless layout_candidate?(proposal)
          if modes.include?("count_unit_price") && proposal["conflicts"].any?
            count = options.find { |option| option["pricing_source_kind"] == "count_unit_price" }
            return false unless proposal["conflicts"] == [ "discount" ] && count.key?("discount")
          end
          if modes.include?("reference_quantity_price")
            return false unless proposal["conflicts"] == [ "reference_expression" ]
            return false if modes.include?("count_unit_price")
          end
        end

        return false unless options.all? do |option|
          option_valid?(
            normalized_hash(option),
            proposal: proposal,
            parent_start: parent_start,
            parent_end: parent_end
          )
        end

        all_evidence_nonoverlapping?(proposal)
      end

      def option_valid?(option, proposal:, parent_start:, parent_end:)
        item_index = proposal["item_index"]
        kind = option["pricing_source_kind"]
        return false unless PRICING_SOURCE_KINDS.include?(kind)
        return false unless option["proposal_id"] == expected_option_id(proposal, kind: kind)

        case kind
        when "count_unit_price"
          expected_keys = option.key?("discount") ? DISCOUNTED_OPTION_KEYS : OPTION_KEYS
          return false unless exact_keys?(option, expected_keys)
          if option.key?("discount")
            return false unless proposal["conflicts"] == [ "discount" ]
            return false unless count_discount_valid?(option, proposal: proposal, parent_start: parent_start, parent_end: parent_end)
          end

          count_option_valid?(option, item_index: item_index, parent_start: parent_start, parent_end: parent_end)
        when "reference_quantity_price"
          return false unless exact_keys?(option, REFERENCE_OPTION_KEYS)

          reference_option_valid?(
            option,
            proposal: proposal,
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end
          )
        when "explicit_line_total"
          expected_keys = option.key?("discount") ? DISCOUNTED_OPTION_KEYS : OPTION_KEYS
          return false unless exact_keys?(option, expected_keys)
          if option.key?("discount")
            return false unless proposal["conflicts"] == [ "discount" ]
            return false unless option.dig("discount", "printed_total_stage") == "before_item_discount"
            return false unless discount_evidence_valid?(option, proposal:, parent_start:, parent_end:)
            return false unless explicit_discount_projection(option)
          end

          explicit_option_valid?(
            option,
            proposal: proposal,
            parent_start: parent_start,
            parent_end: parent_end
          )
        else
          false
        end
      end

      def expected_option_id(proposal, kind:)
        if layout_candidate?(proposal)
          return unless %w[reference_quantity_price explicit_line_total].include?(kind)
          return if layout_only_candidate?(proposal) && kind != "explicit_line_total"

          proposal["candidate_id"].sub(/_item_calculation_mode\z/, "_#{kind}")
        else
          "azure_items_#{proposal['item_index']}_#{kind}"
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
          item_path = "documents[0].fields.Items[#{item_index}]"
          expected_path = "#{item_path}.#{field_name}"
          if evidence_key == "quantity_unit" &&
              normalized_hash(evidence[evidence_key])["source_field_path"] == item_path
            expected_path = item_path
          elsif evidence_key == "quantity" &&
              normalized_hash(evidence[evidence_key])["source_field_path"] == "#{item_path}.Price"
            price_evidence = normalized_hash(evidence["price"])
            quantity_evidence = normalized_hash(evidence["quantity"])
            price_end = price_evidence["provider_span_end"]
            quantity_start = quantity_evidence["provider_span_start"]
            return false unless price_end.is_a?(Integer) && quantity_start.is_a?(Integer) && quantity_start > price_end

            expected_path = "#{item_path}.Price"
          end
          component_evidence_valid?(
            evidence[evidence_key],
            expected_path: expected_path,
            parent_start: parent_start,
            parent_end: parent_end
          )
        end
      end

      def count_discount_valid?(option, proposal:, parent_start:, parent_end:)
        return false unless discount_evidence_valid?(option, proposal:, parent_start:, parent_end:)

        projection = count_discount_projection(option)
        projected_key = option.dig("discount", "printed_total_stage") == "before_item_discount" ? :original_line_total : :projected_amount
        projection && normalized_hash(proposal["printed_line_total"])["amount"] == projection[projected_key].to_s
      end

      def discount_evidence_valid?(option, proposal:, parent_start:, parent_end:)
        discount = normalized_hash(option["discount"])
        return false unless exact_keys?(discount, DISCOUNT_KEYS)
        return false unless DISCOUNT_STAGES.include?(discount["printed_total_stage"])

        evidence = normalized_hash(discount["evidence"])
        return false unless exact_keys?(evidence, DISCOUNT_EVIDENCE_KEYS)
        return false unless evidence.values.all? do |entry|
          component_evidence_valid?(
            entry,
            expected_path: proposal["source_field_path"],
            parent_start: parent_start,
            parent_end: parent_end
          )
        end

        printed_evidence = normalized_hash(normalized_hash(proposal["printed_line_total"])["evidence"])
        evidence.values.all? do |entry|
          if discount["printed_total_stage"] == "before_item_discount"
            entry["provider_span_start"] >= printed_evidence["provider_span_end"].to_i
          else
            entry["provider_span_end"] <= printed_evidence["provider_span_start"].to_i
          end
        end
      end

      def explicit_discount_projection(option)
        discount = normalized_hash(option["discount"])
        return unless exact_integer?(discount["amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return unless exact_decimal?(
          discount["rate"],
          maximum: 1,
          maximum_scale: MAX_DISCOUNT_RATE_SCALE,
          allow_zero: false
        )
        return unless BigDecimal(discount["rate"]) < 1

        ReceiptAmountService.item_discount_projection(
          original_line_total: normalized_hash(option["source"])["line_total_amount"],
          discount_amount: discount["amount"],
          discount_rate: discount["rate"]
        )
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def count_discount_projection(option)
        discount = normalized_hash(option["discount"])
        return unless exact_integer?(discount["amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return unless exact_decimal?(
          discount["rate"],
          maximum: 1,
          maximum_scale: MAX_DISCOUNT_RATE_SCALE,
          allow_zero: false
        )
        return unless BigDecimal(discount["rate"]) < 1

        source = normalized_hash(option["source"])
        ReceiptAmountService.count_item_extension_projection(
          price_amount: source["price_amount"],
          purchased_quantity: source["quantity"],
          purchased_unit_code: source["quantity_unit_code"],
          discount_amount: discount["amount"],
          discount_rate: discount["rate"]
        )
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def reference_option_valid?(option, proposal:, item_index:, parent_start:, parent_end:)
        source = normalized_hash(option["source"])
        evidence = normalized_hash(option["evidence"])
        return false unless exact_keys?(source, REFERENCE_SOURCE_KEYS)
        return false unless exact_keys?(evidence, REFERENCE_EVIDENCE_KEYS)
        expected_candidate_id = if hybrid_layout_candidate?(proposal)
          proposal["candidate_id"].sub(/_item_calculation_mode\z/, "_reference_pricing")
        else
          "azure_items_#{item_index}_reference_pricing"
        end
        return false unless option["source_candidate_id"] == expected_candidate_id
        return false unless reference_source_valid?(source)

        if hybrid_layout_candidate?(proposal)
          return false unless hybrid_reference_option_evidence_valid?(
            evidence,
            proposal: proposal,
            parent_start: parent_start,
            parent_end: parent_end
          )
        else
          paths = {
            "reference_price" => [ "Price" ],
            "reference_quantity" => native_reference_quantity_field_names(
              origin: source["reference_quantity_origin"],
              amount: source["reference_quantity"]
            ),
            "purchased_quantity" => [ "Quantity" ]
          }
          return false unless paths.all? do |evidence_key, field_names|
            field_names.any? do |field_name|
              component_evidence_valid?(
                evidence[evidence_key],
                expected_path: "documents[0].fields.Items[#{item_index}].#{field_name}",
                parent_start: parent_start,
                parent_end: parent_end
              )
            end
          end
          tax_evidence = normalized_hash(evidence["tax_inclusion"])
          if tax_evidence["kind"] == SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KIND
            return false unless single_structured_item_gross_evidence_valid?(
              tax_evidence,
              proposal: proposal,
              parent_start: parent_start,
              parent_end: parent_end
            )
          else
            return false unless reference_tax_component_evidence_valid?(
              tax_evidence,
              item_index: item_index,
              parent_start: parent_start,
              parent_end: parent_end
            )
          end
        end

        reference_projection(source).present?
      end

      def reference_source_valid?(source)
        return false unless exact_decimal?(
          source["reference_price_amount"],
          maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX,
          maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
          allow_zero: true
        )
        return false unless exact_decimal?(
          source["reference_quantity"],
          maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
          maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
          allow_zero: false
        )
        return false unless exact_decimal?(
          source["purchased_quantity"],
          maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
          maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
          allow_zero: false
        )
        return false unless REFERENCE_QUANTITY_ORIGINS.include?(source["reference_quantity_origin"])
        return false unless REFERENCE_TAX_INCLUSIONS.include?(source["reference_price_tax_inclusion"])
        return false unless compatible_reference_units?(
          source["reference_quantity_unit_code"],
          source["purchased_quantity_unit_code"]
        )

        true
      end

      def hybrid_reference_option_evidence_valid?(evidence, proposal:, parent_start:, parent_end:)
        metadata = layout_candidate_metadata(proposal)
        return false if metadata.nil?

        fixed_lines = {
          "reference_price" => metadata.fetch(:reference_line_index),
          "purchased_quantity" => metadata.fetch(:quantity_line_index)
        }
        return false unless fixed_lines.all? do |evidence_key, line_index|
          component_evidence_valid?(
            evidence[evidence_key],
            expected_path: layout_line_path(line_index),
            parent_start: parent_start,
            parent_end: parent_end
          )
        end

        reference_quantity_line = expected_reference_quantity_line_index(metadata)
        return false if reference_quantity_line.nil?
        return false unless component_evidence_valid?(
          evidence["reference_quantity"],
          expected_path: layout_line_path(reference_quantity_line),
          parent_start: parent_start,
          parent_end: parent_end
        )

        single_item_gross_summary_evidence_valid?(
          evidence["tax_inclusion"],
          proposal: proposal,
          parent_start: parent_start,
          parent_end: parent_end
        )
      end

      def layout_line_index(value)
        match = /\Apages\[0\]\.lines\[(\d+)\]\z/.match(value.to_s)
        return if match.nil?

        line_index = Integer(match[1], 10)
        line_index if line_index.between?(0, MAX_LAYOUT_LINE_INDEX)
      rescue ArgumentError
        nil
      end

      def single_item_gross_summary_evidence_valid?(value, proposal:, parent_start:, parent_end:)
        evidence = normalized_hash(value)
        return false unless exact_keys?(evidence, SINGLE_ITEM_GROSS_SUMMARY_EVIDENCE_KEYS)
        return false unless evidence["kind"] == SINGLE_ITEM_GROSS_SUMMARY_EVIDENCE_KIND
        return false unless evidence["policy_contract_version"] == SINGLE_ITEM_GROSS_SUMMARY_POLICY_VERSION
        return false unless evidence["string_index_type"] == proposal["string_index_type"]

        summary = normalized_hash(evidence["summary_total"])
        tax_target = normalized_hash(evidence["gross_tax_target"])
        return false unless exact_keys?(summary, SINGLE_ITEM_GROSS_SUMMARY_TOTAL_KEYS)
        return false unless exact_keys?(tax_target, SINGLE_ITEM_GROSS_SUMMARY_TAX_KEYS)
        return false unless single_item_gross_structural_evidence_valid?(
          summary,
          string_index_type: proposal["string_index_type"]
        )
        return false unless single_item_gross_structural_evidence_valid?(
          tax_target,
          string_index_type: proposal["string_index_type"]
        )
        metadata = layout_candidate_metadata(proposal)
        identity = structured_item_identity_metadata(proposal["item_identity"])
        return false if metadata.nil? || identity.nil?

        block_line_range = metadata.fetch(:name_line_index)..metadata.fetch(:total_line_index)
        return false if block_line_range.cover?(summary["line_index"])
        return false if block_line_range.cover?(tax_target["line_index"])
        return false if summary["line_index"] == tax_target["line_index"]
        return false unless evidence_outside_parent?(summary, parent_start:, parent_end:)
        return false unless evidence_outside_parent?(tax_target, parent_start:, parent_end:)
        return false unless evidence_outside_parent?(
          summary,
          parent_start: identity.fetch(:span_start),
          parent_end: identity.fetch(:span_end)
        )
        return false unless evidence_outside_parent?(
          tax_target,
          parent_start: identity.fetch(:span_start),
          parent_end: identity.fetch(:span_end)
        )
        return false if evidence_ranges_overlap?(summary, tax_target)

        summary_amount = bounded_exact_integer_value(summary["amount"], allow_zero: false)
        net_amount = bounded_exact_integer_value(tax_target["net_amount"], allow_zero: true)
        tax_amount = bounded_exact_integer_value(tax_target["tax_amount"], allow_zero: false)
        gross_amount = bounded_exact_integer_value(tax_target["gross_amount"], allow_zero: false)
        rate = tax_target["rate"]
        return false unless exact_decimal?(
          rate,
          maximum: BigDecimal("1"),
          maximum_scale: MAX_TAX_RATE_SCALE,
          allow_zero: false
        )
        return false if [ summary_amount, net_amount, tax_amount, gross_amount ].any?(&:nil?)

        expected_tax = ReceiptAmountService.apply_rounding(
          BigDecimal(gross_amount.to_s) * BigDecimal(rate) / (BigDecimal("1") + BigDecimal(rate)),
          :floor
        )
        summary_amount == gross_amount && tax_amount == expected_tax &&
          net_amount == gross_amount - expected_tax
      rescue ArgumentError, TypeError
        false
      end

      def single_item_gross_structural_evidence_valid?(value, string_index_type:)
        line_index = value["line_index"]
        value["source_provider"] == LAYOUT_SOURCE_PROVIDER &&
          value["page_index"] == 0 &&
          line_index.is_a?(Integer) && line_index.between?(0, MAX_LAYOUT_LINE_INDEX) &&
          value["source_field_path"] == layout_line_path(line_index) &&
          value["source_field_path"].bytesize <= MAX_PATH_BYTES &&
          value["string_index_type"] == string_index_type &&
          valid_span?(value["provider_span_start"], value["provider_span_end"])
      end

      def single_structured_item_gross_evidence_valid?(
        value,
        proposal:,
        parent_start:,
        parent_end:,
        context: nil
      )
        evidence = normalized_hash(value)
        return false unless exact_keys?(evidence, SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KEYS)
        return false unless proposal["source_provider"] == SOURCE_PROVIDER
        return false unless proposal["item_index"] == 0
        return false unless evidence["kind"] == SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KIND
        return false unless evidence["policy_contract_version"] == SINGLE_STRUCTURED_ITEM_GROSS_POLICY_VERSION
        return false unless evidence["string_index_type"] == proposal["string_index_type"]

        item_parent = normalized_hash(evidence["item_parent"])
        tax_parent = normalized_hash(evidence["tax_detail_parent"])
        return false unless single_structured_item_parent_valid?(
          item_parent,
          expected_keys: SINGLE_STRUCTURED_ITEM_GROSS_ITEM_PARENT_KEYS,
          expected_path: "documents[0].fields.Items[0]",
          index_key: "item_index"
        )
        return false unless single_structured_item_parent_valid?(
          tax_parent,
          expected_keys: SINGLE_STRUCTURED_ITEM_GROSS_TAX_PARENT_KEYS,
          expected_path: "documents[0].fields.TaxDetails[0]",
          index_key: "tax_detail_index"
        )
        return false unless item_parent["source_field_path"] == proposal["source_field_path"]
        return false unless item_parent["item_index"] == proposal["item_index"]
        return false unless item_parent["provider_span_start"] == parent_start
        return false unless item_parent["provider_span_end"] == parent_end
        return false if evidence_ranges_overlap?(item_parent, tax_parent)

        tax_description = normalized_hash(evidence["tax_description"])
        tax_amount = normalized_hash(evidence["tax_amount"])
        document_tax_total = normalized_hash(evidence["document_tax_total"])
        summary_total = normalized_hash(evidence["summary_total"])
        return false unless single_structured_item_line_evidence_valid?(
          tax_description,
          expected_keys: SINGLE_STRUCTURED_ITEM_GROSS_TAX_LINE_KEYS,
          expected_provider: SOURCE_PROVIDER,
          expected_path: "documents[0].fields.TaxDetails[0].Description",
          string_index_type: proposal["string_index_type"],
          index_key: "tax_detail_index"
        )
        return false unless single_structured_item_line_evidence_valid?(
          tax_amount,
          expected_keys: SINGLE_STRUCTURED_ITEM_GROSS_TAX_AMOUNT_KEYS,
          expected_provider: SOURCE_PROVIDER,
          expected_path: "documents[0].fields.TaxDetails[0].Amount",
          string_index_type: proposal["string_index_type"],
          index_key: "tax_detail_index"
        )
        return false unless single_structured_item_line_evidence_valid?(
          document_tax_total,
          expected_keys: SINGLE_STRUCTURED_ITEM_GROSS_AMOUNT_KEYS,
          expected_provider: SOURCE_PROVIDER,
          expected_path: "documents[0].fields.TotalTax",
          string_index_type: proposal["string_index_type"]
        )
        return false unless single_structured_item_line_evidence_valid?(
          summary_total,
          expected_keys: SINGLE_STRUCTURED_ITEM_GROSS_AMOUNT_KEYS,
          expected_provider: "azure_document_total",
          expected_path: layout_line_path(summary_total["line_index"]),
          string_index_type: proposal["string_index_type"]
        )
        return false unless evidence_within_parent?(tax_description, parent: tax_parent)
        return false unless evidence_within_parent?(tax_amount, parent: tax_parent)
        return false if evidence_ranges_overlap?(tax_description, tax_amount)
        return false unless evidence_ranges_equal_or_disjoint?(tax_amount, document_tax_total)
        return false if evidence_ranges_overlap?(summary_total, item_parent)
        return false if evidence_ranges_overlap?(summary_total, tax_parent)

        tax_value = bounded_exact_integer_value(tax_amount["amount"], allow_zero: false)
        tax_total_value = bounded_exact_integer_value(document_tax_total["amount"], allow_zero: false)
        summary_value = bounded_exact_integer_value(summary_total["amount"], allow_zero: false)
        return false if [ tax_value, tax_total_value, summary_value ].any?(&:nil?)
        return false unless tax_value == tax_total_value
        return true if context.nil?

        context_integer_matches?(
          context.dig("candidates", "tax_amount"),
          tax_value.to_s,
          maximum: MAX_AMOUNT,
          allow_zero: false
        ) && context_integer_matches?(
          context.dig("candidates", "total_amount"),
          summary_value.to_s,
          maximum: MAX_AMOUNT,
          allow_zero: false
        )
      rescue ArgumentError, TypeError
        false
      end

      def single_structured_item_parent_valid?(value, expected_keys:, expected_path:, index_key:)
        exact_keys?(value, expected_keys) &&
          value["source_provider"] == SOURCE_PROVIDER &&
          value["source_field_path"] == expected_path &&
          value["source_field_path"].bytesize <= MAX_PATH_BYTES &&
          value[index_key] == 0 &&
          valid_span?(value["provider_span_start"], value["provider_span_end"])
      end

      def single_structured_item_line_evidence_valid?(
        value,
        expected_keys:,
        expected_provider:,
        expected_path:,
        string_index_type:,
        index_key: nil
      )
        return false unless exact_keys?(value, expected_keys)
        return false unless value["source_provider"] == expected_provider
        return false unless value["source_field_path"] == expected_path
        return false unless value["source_field_path"].bytesize <= MAX_PATH_BYTES
        return false unless value["page_index"] == 0
        return false unless value["line_index"].is_a?(Integer)
        return false unless value["line_index"].between?(0, MAX_LAYOUT_LINE_INDEX)
        return false unless value["string_index_type"] == string_index_type
        return false if index_key && value[index_key] != 0

        valid_span?(value["provider_span_start"], value["provider_span_end"])
      end

      def evidence_within_parent?(value, parent:)
        value["provider_span_start"] >= parent["provider_span_start"] &&
          value["provider_span_end"] <= parent["provider_span_end"]
      end

      def evidence_ranges_equal_or_disjoint?(left, right)
        same_range = left["provider_span_start"] == right["provider_span_start"] &&
          left["provider_span_end"] == right["provider_span_end"]
        same_range || !evidence_ranges_overlap?(left, right)
      end

      def evidence_outside_parent?(value, parent_start:, parent_end:)
        value["provider_span_end"] <= parent_start || value["provider_span_start"] >= parent_end
      end

      def evidence_ranges_overlap?(left, right)
        left["provider_span_start"] < right["provider_span_end"] &&
          right["provider_span_start"] < left["provider_span_end"]
      end

      def bounded_exact_integer_value(value, allow_zero:)
        return unless value.is_a?(Integer)
        return unless value.between?(allow_zero ? 0 : 1, MAX_AMOUNT.to_i)

        value
      end

      def compatible_reference_units?(reference_unit_code, purchased_unit_code)
        reference_unit = ReceiptQuantityUnit.unit_for(reference_unit_code)
        purchased_unit = ReceiptQuantityUnit.unit_for(purchased_unit_code)
        reference_unit&.allows_pricing_role?(:reference) &&
          purchased_unit&.allows_pricing_role?(:purchased) &&
          ReceiptQuantityUnit.convertible?(from: purchased_unit_code, to: reference_unit_code)
      end

      def reference_projection(source)
        ReceiptAmountService.reference_item_extension_projection(
          reference_price_amount: source["reference_price_amount"],
          reference_quantity: source["reference_quantity"],
          reference_unit_code: source["reference_quantity_unit_code"],
          purchased_quantity: source["purchased_quantity"],
          purchased_unit_code: source["purchased_quantity_unit_code"]
        )
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def reference_options_match_context?(proposal, context:)
        return true if calculation_layout_candidate?(proposal)
        return true if layout_only_candidate?(proposal)

        references = context.dig("candidates", "reference_pricing_candidates").select do |candidate|
          reference_candidate_claims_valid?(
            candidate,
            item_index: proposal["item_index"],
            proposal: proposal
          )
        end
        option = proposal["options"].find do |entry|
          normalized_hash(entry)["pricing_source_kind"] == "reference_quantity_price"
        end
        return option.nil? if references.empty?
        return false unless references.one? && option

        option == reference_option_for(proposal, context: context)
      end

      def reference_candidate_claims_valid?(candidate, item_index:, proposal: nil)
        expected_id = if proposal && hybrid_layout_candidate?(proposal)
          proposal["candidate_id"].sub(/_item_calculation_mode\z/, "_reference_pricing")
        else
          "azure_items_#{item_index}_reference_pricing"
        end
        candidate["candidate_id"] == expected_id &&
          candidate["item_index"] == item_index &&
          candidate["validation_state"] == "valid" &&
          candidate["rejection_reasons"] == []
      end

      def reference_candidate_valid?(reference_candidate, candidate:, context:)
        return false unless SUPPORTED_STRING_INDEX_TYPES.include?(candidate["string_index_type"])
        if hybrid_layout_candidate?(candidate)
          return hybrid_reference_candidate_valid?(reference_candidate, candidate:, context:)
        end
        return false unless exact_optional_keys?(
          reference_candidate,
          required: REFERENCE_CANDIDATE_REQUIRED_KEYS,
          optional: REFERENCE_CANDIDATE_OPTIONAL_KEYS
        )

        item_index = candidate["item_index"]
        return false unless reference_candidate_claims_valid?(reference_candidate, item_index: item_index)
        return false unless reference_price_component_valid?(
          reference_candidate["reference_price"],
          item_index: item_index,
          parent_start: candidate["provider_span_start"],
          parent_end: candidate["provider_span_end"]
        )
        return false unless reference_quantity_component_valid?(
          reference_candidate["reference_quantity"],
          item_index: item_index,
          parent_start: candidate["provider_span_start"],
          parent_end: candidate["provider_span_end"]
        )
        return false unless purchased_quantity_component_valid?(
          reference_candidate["purchased_quantity"],
          item_index: item_index,
          parent_start: candidate["provider_span_start"],
          parent_end: candidate["provider_span_end"]
        )
        return false unless REFERENCE_TAX_INCLUSIONS.include?(
          reference_candidate["reference_price_tax_inclusion"]
        )
        tax_evidence = normalized_hash(reference_candidate["tax_inclusion_evidence"])
        if tax_evidence["kind"] == SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KIND
          return false unless single_structured_item_gross_evidence_valid?(
            tax_evidence,
            proposal: candidate,
            parent_start: candidate["provider_span_start"],
            parent_end: candidate["provider_span_end"],
            context:
          )
        else
          return false unless reference_tax_evidence_valid?(
            tax_evidence,
            item_index: item_index,
            parent_start: candidate["provider_span_start"],
            parent_end: candidate["provider_span_end"]
          )
        end

        source = reference_source(reference_candidate)
        return false unless compatible_reference_units?(
          source["reference_quantity_unit_code"],
          source["purchased_quantity_unit_code"]
        )

        projection = reference_projection(source)
        return false if projection.nil?

        reference_printed_corroboration_valid?(
          reference_candidate,
          candidate: candidate,
          projection: projection
        )
      end

      def hybrid_reference_candidate_valid?(reference_candidate, candidate:, context:)
        return false unless exact_optional_keys?(
          reference_candidate,
          required: LAYOUT_REFERENCE_CANDIDATE_REQUIRED_KEYS,
          optional: LAYOUT_REFERENCE_CANDIDATE_OPTIONAL_KEYS
        )

        item_index = candidate["item_index"]
        metadata = layout_candidate_metadata(candidate)
        return false if metadata.nil?
        return false unless reference_candidate_claims_valid?(
          reference_candidate,
          item_index: item_index,
          proposal: candidate
        )
        exact_metadata = {
          "source_kind" => LAYOUT_SOURCE_PROVIDER,
          "item_identity" => candidate["item_identity"],
          "destination_kind" => "azure_structured_item",
          "structured_item_index" => item_index,
          "page_index" => 0,
          "name_line_index" => metadata.fetch(:name_line_index),
          "reference_line_index" => metadata.fetch(:reference_line_index),
          "printed_total_line_index" => metadata.fetch(:total_line_index),
          "string_index_type" => candidate["string_index_type"],
          "provider_model_id" => PROVIDER_MODEL_ID,
          "provider_api_version" => PROVIDER_API_VERSION,
          "validation_contract_version" => "azure_item_layout_v1",
          "block_provider_span_start" => candidate["provider_span_start"],
          "block_provider_span_end" => candidate["provider_span_end"]
        }
        return false unless exact_metadata.all? { |key, expected| reference_candidate[key] == expected }
        return false unless exact_owned_line_indexes?(reference_candidate["owned_line_indexes"], metadata:)
        producer_contract = exact_layout_producer_contract(reference_candidate, metadata:)
        return false if producer_contract.nil?

        parent_start = candidate["provider_span_start"]
        parent_end = candidate["provider_span_end"]
        return false unless layout_reference_line_span_valid?(
          reference_candidate,
          metadata:,
          producer_contract:,
          parent_start:,
          parent_end:
        )
        layout_evidence = ->(line_indexes) { { candidate:, line_indexes: } }
        return false unless reference_price_component_valid?(
          reference_candidate["reference_price"],
          item_index:,
          parent_start:,
          parent_end:,
          layout_evidence: layout_evidence.call([ metadata.fetch(:reference_line_index) ])
        )
        reference_quantity_lines = [
          metadata.fetch(:name_line_index) + producer_contract.fetch(:reference_quantity)
        ]
        return false unless reference_quantity_component_valid?(
          reference_candidate["reference_quantity"],
          item_index:,
          parent_start:,
          parent_end:,
          layout_evidence: layout_evidence.call(reference_quantity_lines)
        )
        return false unless purchased_quantity_component_valid?(
          reference_candidate["purchased_quantity"],
          item_index:,
          parent_start:,
          parent_end:,
          layout_evidence: layout_evidence.call([ metadata.fetch(:quantity_line_index) ])
        )
        return false unless reference_candidate["reference_price_tax_inclusion"] == "gross"
        return false unless single_item_gross_summary_evidence_valid?(
          reference_candidate["tax_inclusion_evidence"],
          proposal: candidate,
          parent_start: parent_start,
          parent_end: parent_end
        )
        summary = normalized_hash(reference_candidate.dig("tax_inclusion_evidence", "summary_total"))
        tax_target = normalized_hash(reference_candidate.dig("tax_inclusion_evidence", "gross_tax_target"))
        return false unless context_integer_matches?(
          context.dig("candidates", "total_amount"),
          summary["amount"].to_s,
          maximum: MAX_AMOUNT,
          allow_zero: false
        )
        return false unless context_integer_matches?(
          context.dig("candidates", "tax_amount"),
          tax_target["tax_amount"].to_s,
          maximum: MAX_AMOUNT,
          allow_zero: false
        )

        source = reference_source(reference_candidate)
        return false unless compatible_reference_units?(
          source["reference_quantity_unit_code"],
          source["purchased_quantity_unit_code"]
        )

        projection = reference_projection(source)
        return false if projection.nil?

        hybrid_reference_printed_corroboration_valid?(
          reference_candidate,
          candidate: candidate,
          projection: projection
        )
      end

      def layout_reference_line_span_valid?(
        reference_candidate,
        metadata:,
        producer_contract:,
        parent_start:,
        parent_end:
      )
        line_start = reference_candidate["reference_line_provider_span_start"]
        line_end = reference_candidate["reference_line_provider_span_end"]
        return false unless valid_span?(line_start, line_end)
        return false unless line_start >= parent_start && line_end <= parent_end

        reference_line_index = metadata.fetch(:reference_line_index)
        reference_price_evidence = normalized_hash(reference_candidate.dig("reference_price", "evidence"))
        return false unless evidence_within_line_span?(
          reference_price_evidence,
          expected_line_index: reference_line_index,
          line_start:,
          line_end:
        )

        reference_quantity_line_index =
          metadata.fetch(:name_line_index) + producer_contract.fetch(:reference_quantity)
        return true unless reference_quantity_line_index == reference_line_index

        evidence_within_line_span?(
          normalized_hash(reference_candidate.dig("reference_quantity", "evidence")),
          expected_line_index: reference_line_index,
          line_start:,
          line_end:
        )
      end

      def evidence_within_line_span?(evidence, expected_line_index:, line_start:, line_end:)
        evidence["line_index"] == expected_line_index &&
          evidence["source_field_path"] == layout_line_path(expected_line_index) &&
          evidence["provider_span_start"].is_a?(Integer) &&
          evidence["provider_span_end"].is_a?(Integer) &&
          evidence["provider_span_start"] >= line_start && evidence["provider_span_end"] <= line_end
      end

      def layout_reference_context_evidence_valid?(
        value,
        candidate:,
        parent_start:,
        parent_end:,
        allowed_line_indexes: nil,
        expected_line_index: nil
      )
        evidence = normalized_hash(value)
        line_index = evidence["line_index"]
        allowed_line_indexes ||= [ expected_line_index ]
        exact_keys?(evidence, LAYOUT_REFERENCE_CONTEXT_EVIDENCE_KEYS) &&
          evidence["source_provider"] == LAYOUT_SOURCE_PROVIDER && evidence["page_index"] == 0 &&
          allowed_line_indexes.include?(line_index) &&
          evidence["source_field_path"] == layout_line_path(line_index) &&
          evidence["string_index_type"] == candidate["string_index_type"] &&
          valid_span?(evidence["provider_span_start"], evidence["provider_span_end"]) &&
          evidence["provider_span_start"] >= parent_start && evidence["provider_span_end"] <= parent_end
      end

      def reference_source(candidate)
        {
          "reference_price_amount" => candidate.dig("reference_price", "amount"),
          "reference_quantity" => candidate.dig("reference_quantity", "amount"),
          "reference_quantity_unit_code" => candidate.dig("reference_quantity", "unit_code"),
          "reference_quantity_origin" => candidate.dig("reference_quantity", "origin"),
          "purchased_quantity" => candidate.dig("purchased_quantity", "amount"),
          "purchased_quantity_unit_code" => candidate.dig("purchased_quantity", "unit_code"),
          "reference_price_tax_inclusion" => candidate["reference_price_tax_inclusion"]
        }
      end

      def reference_price_component_valid?(value, item_index:, parent_start:, parent_end:, layout_evidence: nil)
        component = normalized_hash(value)
        exact_keys?(component, REFERENCE_PRICE_COMPONENT_KEYS) &&
          exact_decimal?(
            component["amount"],
            maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX,
            maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
            allow_zero: true
          ) &&
          reference_component_evidence_valid?(
            component["evidence"],
            field_name: "Price",
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end,
            layout_evidence:
          )
      end

      def reference_quantity_component_valid?(value, item_index:, parent_start:, parent_end:, layout_evidence: nil)
        component = normalized_hash(value)
        field_names = if layout_evidence.nil?
          native_reference_quantity_field_names(
            origin: component["origin"],
            amount: component["amount"]
          )
        else
          [ "Price" ]
        end
        exact_keys?(component, REFERENCE_QUANTITY_COMPONENT_KEYS) &&
          exact_decimal?(
            component["amount"],
            maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
            maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
            allow_zero: false
          ) &&
          REFERENCE_UNIT_STATUSES.include?(component["unit_status"]) &&
          REFERENCE_QUANTITY_ORIGINS.include?(component["origin"]) &&
          ReceiptQuantityUnit.unit_for(component["unit_code"])&.allows_pricing_role?(:reference) &&
          field_names.any? do |field_name|
            reference_component_evidence_valid?(
              component["evidence"],
              field_name: field_name,
              item_index: item_index,
              parent_start: parent_start,
              parent_end: parent_end,
              layout_evidence:
            )
          end
      end

      def native_reference_quantity_field_names(origin:, amount:)
        return [ "Price" ] if origin == "explicit"
        return [] unless origin == "implicit_per_unit" && amount == "1"

        %w[Price QuantityUnit]
      end

      def purchased_quantity_component_valid?(value, item_index:, parent_start:, parent_end:, layout_evidence: nil)
        component = normalized_hash(value)
        exact_keys?(component, PURCHASED_QUANTITY_COMPONENT_KEYS) &&
          exact_decimal?(
            component["amount"],
            maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
            maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
            allow_zero: false
          ) &&
          REFERENCE_UNIT_STATUSES.include?(component["unit_status"]) &&
          ReceiptQuantityUnit.unit_for(component["unit_code"])&.allows_pricing_role?(:purchased) &&
          reference_component_evidence_valid?(
            component["evidence"],
            field_name: "Quantity",
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end,
            layout_evidence:
          )
      end

      def reference_component_evidence_valid?(
        value,
        field_name:,
        item_index:,
        parent_start:,
        parent_end:,
        layout_evidence:
      )
        if layout_evidence
          return layout_reference_context_evidence_valid?(
            value,
            candidate: layout_evidence.fetch(:candidate),
            allowed_line_indexes: layout_evidence.fetch(:line_indexes),
            parent_start:,
            parent_end:
          )
        end

        reference_context_evidence_valid?(
          value,
          expected_path: "documents[0].fields.Items[#{item_index}].#{field_name}",
          item_index:,
          parent_start:,
          parent_end:
        )
      end

      def reference_context_evidence_valid?(
        value,
        expected_path:,
        item_index:,
        parent_start:,
        parent_end:
      )
        evidence = normalized_hash(value)
        exact_keys?(evidence, REFERENCE_CONTEXT_EVIDENCE_KEYS) &&
          evidence["source_provider"] == SOURCE_PROVIDER &&
          evidence["source_field_path"] == expected_path &&
          evidence["source_field_path"].bytesize <= MAX_PATH_BYTES &&
          evidence["item_index"] == item_index &&
          valid_span?(evidence["provider_span_start"], evidence["provider_span_end"]) &&
          evidence["provider_span_start"] >= parent_start &&
          evidence["provider_span_end"] <= parent_end
      end

      def reference_tax_evidence_valid?(value, item_index:, parent_start:, parent_end:)
        [
          "documents[0].fields.Items[#{item_index}].Price",
          "documents[0].fields.Items[#{item_index}]"
        ].any? do |expected_path|
          reference_context_evidence_valid?(
            value,
            expected_path: expected_path,
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end
          )
        end
      end

      def reference_tax_component_evidence_valid?(value, item_index:, parent_start:, parent_end:)
        [
          "documents[0].fields.Items[#{item_index}].Price",
          "documents[0].fields.Items[#{item_index}]"
        ].any? do |expected_path|
          component_evidence_valid?(
            value,
            expected_path: expected_path,
            parent_start: parent_start,
            parent_end: parent_end
          )
        end
      end

      def reference_printed_corroboration_valid?(reference_candidate, candidate:, projection:)
        printed = normalized_hash(reference_candidate["printed_line_total"])
        corroboration = normalized_hash(reference_candidate["corroboration"])
        explicit = Array(candidate["options"]).find do |option|
          normalized_hash(option)["pricing_source_kind"] == "explicit_line_total"
        end
        root_printed = normalized_hash(candidate["printed_line_total"])
        return explicit.nil? && root_printed.empty? && corroboration.empty? if printed.empty?
        return false if explicit.nil? || root_printed.empty? || corroboration.empty?
        return false unless exact_keys?(printed, REFERENCE_PRINTED_TOTAL_KEYS)

        item_index = candidate["item_index"]
        return false unless exact_integer?(printed["amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return false unless reference_context_evidence_valid?(
          printed["evidence"],
          expected_path: "documents[0].fields.Items[#{item_index}].TotalPrice",
          item_index: item_index,
          parent_start: candidate["provider_span_start"],
          parent_end: candidate["provider_span_end"]
        )
        return false unless normalized_hash(explicit["source"])["line_total_amount"] == printed["amount"]
        return false unless root_printed["amount"] == printed["amount"]
        root_evidence = normalized_hash(root_printed["evidence"])
        printed_evidence = proposal_evidence(printed["evidence"])
        return false unless root_evidence["source_field_path"] == printed_evidence["source_field_path"]
        return false unless printed_evidence["provider_span_start"] >= root_evidence["provider_span_start"]
        return false unless printed_evidence["provider_span_end"] <= root_evidence["provider_span_end"]

        reference_corroboration_valid?(
          corroboration,
          printed_amount: printed["amount"],
          projection: projection
        )
      end

      def hybrid_reference_printed_corroboration_valid?(reference_candidate, candidate:, projection:)
        printed = normalized_hash(reference_candidate["printed_line_total"])
        corroboration = normalized_hash(reference_candidate["corroboration"])
        root_printed = normalized_hash(candidate["printed_line_total"])
        explicit = Array(candidate["options"]).find do |option|
          normalized_hash(option)["pricing_source_kind"] == "explicit_line_total"
        end
        return false if [ printed, corroboration, root_printed ].any?(&:empty?) || explicit.nil?
        return false unless exact_keys?(printed, REFERENCE_PRINTED_TOTAL_KEYS)

        metadata = layout_candidate_metadata(candidate)
        return false if metadata.nil?
        return false unless exact_integer?(printed["amount"], maximum: MAX_AMOUNT, allow_zero: true)
        return false unless layout_reference_context_evidence_valid?(
          printed["evidence"],
          candidate: candidate,
          expected_line_index: metadata.fetch(:total_line_index),
          parent_start: candidate["provider_span_start"],
          parent_end: candidate["provider_span_end"]
        )
        return false unless normalized_hash(explicit["source"])["line_total_amount"] == printed["amount"]
        return false unless root_printed["amount"] == printed["amount"]
        return false unless proposal_evidence(printed["evidence"]) == proposal_evidence(root_printed["evidence"])

        summary = normalized_hash(reference_candidate.dig("tax_inclusion_evidence", "summary_total"))
        return false unless summary["amount"].to_s == printed["amount"]

        reference_corroboration_valid?(
          corroboration,
          printed_amount: printed["amount"],
          projection: projection
        )
      end

      def reference_corroboration_valid?(value, printed_amount:, projection:)
        return false unless exact_keys?(value, REFERENCE_CORROBORATION_KEYS)

        exact_amount = normalized_hash(value["exact_amount"])
        matches = value["rounding_matches"]
        exact_keys?(exact_amount, REFERENCE_EXACT_AMOUNT_KEYS) &&
          exact_amount["numerator"] == projection.fetch(:exact_amount).numerator.to_s &&
          exact_amount["denominator"] == projection.fetch(:exact_amount).denominator.to_s &&
          value["projected_amount"] == projection.fetch(:projected_amount) &&
          value["printed_line_total"] == printed_amount &&
          matches.is_a?(Array) && matches.uniq == matches &&
          (matches - REFERENCE_ROUNDING_MATCHES).empty?
      end

      def explicit_option_valid?(option, proposal:, parent_start:, parent_end:)
        source = normalized_hash(option["source"])
        evidence = normalized_hash(option["evidence"])
        return false unless exact_keys?(source, EXPLICIT_SOURCE_KEYS)
        return false unless exact_keys?(evidence, EXPLICIT_EVIDENCE_KEYS)
        return false unless exact_integer?(source["line_total_amount"], maximum: MAX_AMOUNT, allow_zero: true)

        component_evidence_valid?(
          evidence["line_total"],
          expected_path: explicit_total_path(proposal),
          parent_start: parent_start,
          parent_end: parent_end
        )
      end

      def printed_line_total_valid?(value, proposal:, parent_start:, parent_end:)
        return true if value.nil?

        component = normalized_hash(value)
        exact_keys?(component, COMPONENT_KEYS) &&
          exact_integer?(component["amount"], maximum: MAX_AMOUNT, allow_zero: true) &&
          component_evidence_valid?(
            component["evidence"],
            expected_path: explicit_total_path(proposal),
            parent_start: parent_start,
            parent_end: parent_end
          )
      end

      def explicit_total_path(proposal)
        if calculation_layout_candidate?(proposal)
          explicit = proposal["options"].find { |option| option["pricing_source_kind"] == "explicit_line_total" }
          return explicit&.dig("evidence", "line_total", "source_field_path")
        end

        if layout_candidate?(proposal)
          metadata = if hybrid_layout_candidate?(proposal)
            layout_candidate_metadata(proposal)
          else
            layout_identity_metadata(proposal)
          end
          layout_line_path(metadata.fetch(:total_line_index)) if metadata
        else
          "documents[0].fields.Items[#{proposal['item_index']}].TotalPrice"
        end
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
        discounts = proposal["options"].filter_map { |option| option["discount"] }
        return false if discounts.uniq.size > 1

        evidence.concat(normalized_hash(normalized_hash(discounts.first)["evidence"]).values)
        proposal["options"].each do |option|
          normalized_hash(option["evidence"]).each_value do |entry|
            normalized = normalized_hash(entry)
            if normalized["kind"] == SINGLE_ITEM_GROSS_SUMMARY_EVIDENCE_KIND
              evidence << normalized["summary_total"]
              evidence << normalized["gross_tax_target"]
            elsif normalized["kind"] == SINGLE_STRUCTURED_ITEM_GROSS_EVIDENCE_KIND
              evidence << normalized["tax_description"]
              evidence << normalized["tax_amount"]
              evidence << normalized["summary_total"]
              document_tax_total = normalized_hash(normalized["document_tax_total"])
              tax_amount = normalized_hash(normalized["tax_amount"])
              evidence << document_tax_total unless evidence_ranges_equal?(tax_amount, document_tax_total)
            else
              evidence << entry
            end
          end
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

      def evidence_ranges_equal?(left, right)
        left["provider_span_start"] == right["provider_span_start"] &&
          left["provider_span_end"] == right["provider_span_end"]
      end

      def collection_valid?(proposals, context:)
        return false unless proposals.is_a?(Array) && proposals.size <= MAX_SETS
        return false unless calculation_layout_blocks_nonoverlapping?(proposals)

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

      def calculation_layout_blocks_nonoverlapping?(proposals)
        layouts = proposals.select { |proposal| calculation_layout_candidate?(proposal) }
          .sort_by { |proposal| proposal["provider_span_start"] }
        layouts.each_cons(2).all? do |previous, following|
          previous["provider_span_end"] <= following["provider_span_start"]
        end
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
        return nil unless truncated["reference_pricing_candidates"] == false
        return nil unless truncated["item_calculation_mode_candidates"] == false

        candidate_counts = bounded_context_hash(source["candidate_counts"], maximum_entries: 24)
        return nil if candidate_counts.nil?
        item_counts = exact_count_metadata(candidate_counts["items"])
        reference_counts = exact_count_metadata(candidate_counts["reference_pricing_candidates"])
        proposal_counts = exact_count_metadata(candidate_counts["item_calculation_mode_candidates"])
        return nil if item_counts.nil? || reference_counts.nil? || proposal_counts.nil?

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
            maximum: MAX_ID_BYTES
          )
          return nil unless context_item_identity_valid?(identity)

          {
            "ocr_item_identity" => identity,
            "price" => item["price"],
            "quantity" => item["quantity"],
            "quantity_unit_code" => item["quantity_unit_code"],
            "discount_amount" => item["discount_amount"],
            "discount_rate" => item["discount_rate"],
            "line_total" => item["line_total"],
            "original_line_total" => item["original_line_total"]
          }.compact
        end
        identities = items.filter_map { |item| item["ocr_item_identity"] }
        return nil unless identities.uniq.size == identities.size

        raw_reference_candidates = candidates["reference_pricing_candidates"]
        return nil unless raw_reference_candidates.is_a?(Array) && raw_reference_candidates.size <= MAX_SETS
        return nil unless reference_counts["actual_count"] == raw_reference_candidates.size
        return nil unless reference_counts["snapshot_count"] == raw_reference_candidates.size

        reference_candidates = raw_reference_candidates.map do |candidate|
          bounded_normalized_hash(
            candidate,
            maximum_nodes: MAX_REFERENCE_CANDIDATE_NODES,
            maximum_collection_size: MAX_REFERENCE_CANDIDATE_COLLECTION_SIZE
          )
        end
        return nil if reference_candidates.any?(&:nil?)
        reference_candidate_ids = reference_candidates.filter_map { |candidate| candidate["candidate_id"] }
        return nil unless reference_candidate_ids.size == reference_candidates.size
        return nil unless reference_candidate_ids.all? do |candidate_id|
          bounded_string?(candidate_id, maximum: MAX_ID_BYTES)
        end
        return nil unless reference_candidate_ids.uniq.size == reference_candidate_ids.size

        {
          "schema_version" => OCR_RESULT_SCHEMA_VERSION,
          "candidates" => {
            "items" => items,
            "reference_pricing_candidates" => reference_candidates,
            "total_amount" => bounded_context_amount(candidates["total_amount"], allow_zero: false),
            "tax_amount" => bounded_context_amount(candidates["tax_amount"], allow_zero: false)
          }.compact,
          "candidate_counts" => {
            "reference_pricing_candidates" => reference_counts,
            "item_calculation_mode_candidates" => proposal_counts
          }
        }
      end

      def context_item_identity_valid?(identity)
        identity.match?(STRUCTURED_ITEM_IDENTITY_PATTERN) || identity.match?(LAYOUT_ITEM_IDENTITY_PATTERN) ||
          calculation_layout_identity_metadata(identity).present?
      end

      def bounded_context_amount(value, allow_zero:)
        case value
        when Numeric
          decimal = BigDecimal(value.to_s)
          return unless decimal.finite? && decimal.frac.zero?
          return unless decimal.between?(allow_zero ? 0 : 1, MAX_AMOUNT)

          decimal.to_i
        when String
          return unless exact_integer?(value, maximum: MAX_AMOUNT, allow_zero: allow_zero)

          value
        end
      rescue ArgumentError, TypeError
        nil
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

      def exact_decimal?(value, maximum:, maximum_scale:, allow_zero:)
        return false unless bounded_string?(
          value,
          maximum: MAX_EXACT_NUMBER_BYTES,
          pattern: EXACT_DECIMAL_PATTERN
        )

        decimal = BigDecimal(value)
        scale = value.include?(".") ? value.split(".", 2).last.length : 0
        decimal.finite? && scale <= maximum_scale &&
          (allow_zero ? decimal >= 0 : decimal.positive?) && decimal <= maximum &&
          canonical_decimal_string(decimal) == value
      rescue ArgumentError
        false
      end

      def canonical_decimal_string(value)
        value.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, '\\1')
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

      def exact_optional_keys?(value, required:, optional:)
        return false unless value.is_a?(Hash)

        keys = value.keys
        (required - keys).empty? && (keys - required - optional).empty?
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
