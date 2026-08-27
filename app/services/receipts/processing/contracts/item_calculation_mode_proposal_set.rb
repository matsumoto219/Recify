require "digest"
require "json"

module Receipts::Processing::Contracts
  class ItemCalculationModeProposalSet
    SCHEMA_VERSION = "item_calculation_mode_proposal_set_v1"
    CREATION_STAGE = "ocr_validation"
    SOURCE_PROVIDER = "azure_structured"
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
    MAX_NORMALIZED_NODES = 128
    MAX_REFERENCE_CANDIDATE_NODES = 192
    MAX_NORMALIZED_DEPTH = 8
    MAX_NORMALIZED_COLLECTION_SIZE = 24
    MAX_NORMALIZED_STRING_BYTES = 512
    MAX_AMOUNT = BigDecimal("999999999999")
    MAX_QUANTITY = BigDecimal("9999")

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
    ROOT_OPTIONAL_KEYS = %w[printed_line_total].freeze
    ROOT_KEYS = (ROOT_REQUIRED_KEYS + ROOT_OPTIONAL_KEYS).freeze
    OPTION_KEYS = %w[proposal_id pricing_source_kind source evidence].freeze
    REFERENCE_OPTION_KEYS = (OPTION_KEYS + %w[source_candidate_id]).freeze
    COUNT_SOURCE_KEYS = %w[price_amount quantity quantity_unit_code].freeze
    COUNT_EVIDENCE_KEYS = %w[price quantity quantity_unit].freeze
    REFERENCE_SOURCE_KEYS = %w[
      reference_price_amount reference_quantity reference_quantity_unit_code
      reference_quantity_origin purchased_quantity purchased_quantity_unit_code
      reference_price_tax_inclusion
    ].freeze
    REFERENCE_EVIDENCE_KEYS = %w[
      reference_price reference_quantity purchased_quantity tax_inclusion
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

        options = candidate["options"].dup
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
          "provider_model_id" => candidate["provider_model_id"],
          "provider_api_version" => candidate["provider_api_version"],
          "string_index_type" => candidate["string_index_type"],
          "source_field_path" => candidate["source_field_path"],
          "provider_span_start" => candidate["provider_span_start"],
          "provider_span_end" => candidate["provider_span_end"],
          "destination_evidence" => candidate["destination_evidence"],
          "conflicts" => candidate["conflicts"],
          "options" => options
        }
        proposal["printed_line_total"] = candidate["printed_line_total"] if candidate["printed_line_total"]
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
        return unless SUPPORTED_STRING_INDEX_TYPES.include?(candidate["string_index_type"])

        item_index = candidate["item_index"]
        matches = context.dig("candidates", "reference_pricing_candidates").select do |reference_candidate|
          reference_candidate["item_index"] == item_index &&
            reference_candidate["candidate_id"] == "azure_items_#{item_index}_reference_pricing"
        end
        return unless matches.one?

        reference_candidate = matches.sole
        return unless reference_candidate_valid?(
          reference_candidate,
          candidate: candidate
        )

        {
          "proposal_id" => "azure_items_#{item_index}_reference_quantity_price",
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
            "tax_inclusion" => proposal_evidence(reference_candidate["tax_inclusion_evidence"])
          }
        }
      end

      def proposal_evidence(value)
        evidence = normalized_hash(value)
        COMPONENT_EVIDENCE_KEYS.to_h { |key| [ key, evidence[key] ] }
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
        return false unless reference_options_match_context?(proposal, context: context)
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
        if modes.include?("reference_quantity_price")
          return false unless proposal["conflicts"] == [ "reference_expression" ]
          return false if modes.include?("count_unit_price")
        end

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
        kind = option["pricing_source_kind"]
        return false unless PRICING_SOURCE_KINDS.include?(kind)
        return false unless option["proposal_id"] == "azure_items_#{item_index}_#{kind}"

        case kind
        when "count_unit_price"
          return false unless exact_keys?(option, OPTION_KEYS)

          count_option_valid?(option, item_index: item_index, parent_start: parent_start, parent_end: parent_end)
        when "reference_quantity_price"
          return false unless exact_keys?(option, REFERENCE_OPTION_KEYS)

          reference_option_valid?(
            option,
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end
          )
        when "explicit_line_total"
          return false unless exact_keys?(option, OPTION_KEYS)

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

      def reference_option_valid?(option, item_index:, parent_start:, parent_end:)
        source = normalized_hash(option["source"])
        evidence = normalized_hash(option["evidence"])
        return false unless exact_keys?(source, REFERENCE_SOURCE_KEYS)
        return false unless exact_keys?(evidence, REFERENCE_EVIDENCE_KEYS)
        return false unless option["source_candidate_id"] == "azure_items_#{item_index}_reference_pricing"
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

        paths = {
          "reference_price" => "Price",
          "reference_quantity" => "Price",
          "purchased_quantity" => "Quantity"
        }
        return false unless paths.all? do |evidence_key, field_name|
          component_evidence_valid?(
            evidence[evidence_key],
            expected_path: "documents[0].fields.Items[#{item_index}].#{field_name}",
            parent_start: parent_start,
            parent_end: parent_end
          )
        end
        return false unless reference_tax_component_evidence_valid?(
          evidence["tax_inclusion"],
          item_index: item_index,
          parent_start: parent_start,
          parent_end: parent_end
        )

        reference_projection(source).present?
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
        references = context.dig("candidates", "reference_pricing_candidates").select do |candidate|
          reference_candidate_claims_valid?(candidate, item_index: proposal["item_index"])
        end
        option = proposal["options"].find do |entry|
          normalized_hash(entry)["pricing_source_kind"] == "reference_quantity_price"
        end
        return option.nil? if references.empty?
        return false unless references.one? && option

        option == reference_option_for(proposal, context: context)
      end

      def reference_candidate_claims_valid?(candidate, item_index:)
        candidate["candidate_id"] == "azure_items_#{item_index}_reference_pricing" &&
          candidate["item_index"] == item_index &&
          candidate["validation_state"] == "valid" &&
          candidate["rejection_reasons"] == []
      end

      def reference_candidate_valid?(reference_candidate, candidate:)
        return false unless SUPPORTED_STRING_INDEX_TYPES.include?(candidate["string_index_type"])
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
        return false unless reference_tax_evidence_valid?(
          reference_candidate["tax_inclusion_evidence"],
          item_index: item_index,
          parent_start: candidate["provider_span_start"],
          parent_end: candidate["provider_span_end"]
        )

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

      def reference_price_component_valid?(value, item_index:, parent_start:, parent_end:)
        component = normalized_hash(value)
        exact_keys?(component, REFERENCE_PRICE_COMPONENT_KEYS) &&
          exact_decimal?(
            component["amount"],
            maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX,
            maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
            allow_zero: true
          ) &&
          reference_context_evidence_valid?(
            component["evidence"],
            expected_path: "documents[0].fields.Items[#{item_index}].Price",
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end
          )
      end

      def reference_quantity_component_valid?(value, item_index:, parent_start:, parent_end:)
        component = normalized_hash(value)
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
          reference_context_evidence_valid?(
            component["evidence"],
            expected_path: "documents[0].fields.Items[#{item_index}].Price",
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end
          )
      end

      def purchased_quantity_component_valid?(value, item_index:, parent_start:, parent_end:)
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
          reference_context_evidence_valid?(
            component["evidence"],
            expected_path: "documents[0].fields.Items[#{item_index}].Quantity",
            item_index: item_index,
            parent_start: parent_start,
            parent_end: parent_end
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

        raw_reference_candidates = candidates["reference_pricing_candidates"]
        return nil unless raw_reference_candidates.is_a?(Array) && raw_reference_candidates.size <= MAX_SETS
        return nil unless reference_counts["actual_count"] == raw_reference_candidates.size
        return nil unless reference_counts["snapshot_count"] == raw_reference_candidates.size

        reference_candidates = raw_reference_candidates.map do |candidate|
          bounded_normalized_hash(candidate, maximum_nodes: MAX_REFERENCE_CANDIDATE_NODES)
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
            "reference_pricing_candidates" => reference_candidates
          },
          "candidate_counts" => {
            "reference_pricing_candidates" => reference_counts,
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
