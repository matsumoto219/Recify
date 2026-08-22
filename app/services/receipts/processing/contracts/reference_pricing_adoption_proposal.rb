require "digest"

module Receipts::Processing::Contracts
  class ReferencePricingAdoptionProposal
    SCHEMA_VERSION = "reference_pricing_adoption_proposal_v1"
    CREATION_STAGE = "ocr_validation"
    SOURCE_KIND = "azure_line_group"
    PROVIDER_MODEL_ID = "prebuilt-receipt"
    PROVIDER_API_VERSION = "2024-11-30"
    VALIDATION_CONTRACT_VERSION = "azure_line_group_v1"
    ANALYSIS_PROFILE_COUNTRY_CODE = "JPN"
    DESTINATION_CONTRACT_VERSION = "azure_line_group_destination_v1"
    DESTINATION_KIND = "reference_line_prefix"
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"
    STRING_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
    ROUNDING_MATCHES = %w[floor half_up ceil].freeze
    MAX_SERIALIZED_BYTES = 4096
    MAX_ID_BYTES = 160
    MAX_PATH_BYTES = 256
    MAX_EXACT_NUMBER_BYTES = 64
    MAX_PROVIDER_SPAN = 10_000_000
    MAX_LINE_INDEX = 149
    MAX_WORD_INDEX = 4_799
    MAX_NAME_WORDS = 8
    TAX_WORD_COUNT = 2
    MAX_CONTEXT_LINES = 150
    MAX_CONTEXT_LINE_BYTES = 500
    MAX_NORMALIZED_NODES = 160
    MAX_NORMALIZED_DEPTH = 8
    MAX_NORMALIZED_COLLECTION_SIZE = 24
    MAX_NORMALIZED_STRING_BYTES = 512
    CONTROL_CHARACTER_PATTERN =
      /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
    EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d*[1-9])?\z/.freeze
    CANDIDATE_ID_PATTERN = /\Aazure_line_group_p0_l\d+_l\d+_reference_pricing\z/.freeze
    DESTINATION_ID_PATTERN = /\Aazure_line_group_destination_p0_name_l\d+_s\d+_e\d+_ref_l\d+_qty_l\d+\z/.freeze
    LINE_PATH_PATTERN = /\Apages\[0\]\.lines\[\d+\]\z/.freeze
    WORD_PATH_PATTERN = /\Apages\[0\]\.words\[\d+\]\z/.freeze

    ROOT_KEYS = %w[
      schema_version creation_stage source_kind provider_model_id provider_api_version
      string_index_type candidate_id validation_state validation_contract_version
      analysis_profile_country_code
      destination block_span reference_price reference_quantity purchased_quantity
      reference_price_tax_inclusion tax_inclusion_evidence corroboration
      integrity_checksum
    ].freeze
    INTEGRITY_CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    DESTINATION_KEYS = %w[
      contract_version kind identity page_index name_line_index reference_line_index
      purchased_quantity_line_index normalized_name_grapheme_length evidence
    ].freeze
    DESTINATION_EVIDENCE_KEYS = %w[
      source_provider source_field_path page_index line_index string_index_type
      provider_span_start provider_span_end word_spans tax_word_spans
    ].freeze
    WORD_SPAN_KEYS = %w[
      source_field_path word_index provider_span_start provider_span_end
    ].freeze
    BLOCK_SPAN_KEYS = %w[provider_span_start provider_span_end].freeze
    PRICE_KEYS = %w[amount evidence].freeze
    REFERENCE_QUANTITY_KEYS = %w[amount unit_code origin evidence].freeze
    PURCHASED_QUANTITY_KEYS = %w[amount unit_code evidence].freeze
    EVIDENCE_KEYS = %w[
      source_provider source_field_path string_index_type provider_span_start provider_span_end
    ].freeze
    CORROBORATION_KEYS = %w[state rounding_matches].freeze

    class << self
      def build(candidate:, ocr_snapshot:, source_case_preserved_lines:)
        candidate = bounded_normalized_hash(candidate)
        context = adoption_context(ocr_snapshot)
        diagnostic = diagnostic_candidate(context)
        return nil if candidate.blank? || context.nil? || diagnostic.nil?
        return nil unless source_lines_lossless?(
          source_case_preserved_lines,
          context:,
          destination: diagnostic["destination_item_identity"]
        )

        summary = normalized_hash(candidate["summary_total_corroboration"])
        projection = projection_for(candidate)
        return nil unless source_candidate_valid?(candidate, diagnostic:, summary:, projection:)

        proposal = {
          "schema_version" => SCHEMA_VERSION,
          "creation_stage" => CREATION_STAGE,
          "source_kind" => SOURCE_KIND,
          "provider_model_id" => PROVIDER_MODEL_ID,
          "provider_api_version" => PROVIDER_API_VERSION,
          "string_index_type" => diagnostic["string_index_type"],
          "candidate_id" => diagnostic["candidate_id"],
          "validation_state" => "valid",
          "validation_contract_version" => VALIDATION_CONTRACT_VERSION,
          "analysis_profile_country_code" => ANALYSIS_PROFILE_COUNTRY_CODE,
          "destination" => diagnostic["destination_item_identity"],
          "block_span" => {
            "provider_span_start" => candidate["block_provider_span_start"],
            "provider_span_end" => candidate["block_provider_span_end"]
          },
          "reference_price" => component_with_exact_source(
            candidate["reference_price"],
            diagnostic["reference_price"]
          ),
          "reference_quantity" => component_with_exact_source(
            candidate["reference_quantity"],
            diagnostic["reference_quantity"],
            unit: true,
            origin: true
          ),
          "purchased_quantity" => component_with_exact_source(
            candidate["purchased_quantity"],
            diagnostic["purchased_quantity"],
            unit: true
          ),
          "reference_price_tax_inclusion" => "gross",
          "tax_inclusion_evidence" => diagnostic["tax_inclusion_evidence"],
          "corroboration" => {
            "state" => "matched",
            "rounding_matches" => Array(summary["rounding_matches"])
          }
        }
        proposal["integrity_checksum"] = integrity_checksum(proposal, context:)

        from_snapshot(proposal, ocr_snapshot: context)
      rescue ArgumentError, KeyError, TypeError
        nil
      end

      def from_snapshot(value, ocr_snapshot:)
        proposal = bounded_normalized_hash(value)
        return nil if proposal.nil?

        context = adoption_context(ocr_snapshot)
        return nil if context.nil?
        return nil unless fixed_shape?(proposal)
        return nil unless serialized_within_bound?(proposal)
        return nil unless integrity_valid?(proposal, context:)
        return nil unless context_valid?(context, proposal:)
        return nil unless source_fields_valid?(proposal)

        deep_copy(proposal)
      rescue ArgumentError, JSON::GeneratorError, KeyError, TypeError
        nil
      end

      private

      def source_candidate_valid?(candidate, diagnostic:, summary:, projection:)
        return false unless candidate["candidate_id"] == diagnostic["candidate_id"]
        return false unless candidate["source_kind"] == SOURCE_KIND
        return false unless candidate["provider_model_id"] == PROVIDER_MODEL_ID
        return false unless candidate["provider_api_version"] == PROVIDER_API_VERSION
        return false unless candidate["validation_contract_version"] == VALIDATION_CONTRACT_VERSION
        return false unless candidate["analysis_profile_country_code"] == ANALYSIS_PROFILE_COUNTRY_CODE
        return false unless candidate["validation_state"] == "valid"
        return false unless Array(candidate["rejection_reasons"]).empty?
        return false unless candidate["printed_line_total"].nil? && candidate["corroboration"].nil?
        return false unless candidate["reference_price_tax_inclusion"] == "gross"
        return false unless candidate["destination_item_identity"] == diagnostic["destination_item_identity"]
        return false unless summary_projection_valid?(summary, projection:)

        true
      end

      def summary_projection_valid?(summary, projection:)
        return false if summary.blank? || projection.nil?

        exact_amount = normalized_hash(summary["exact_amount"])
        matches = Array(summary["rounding_matches"])
        matches.any? && matches.uniq == matches && (matches - ROUNDING_MATCHES).empty? &&
          summary["projected_amount"] == projection.fetch(:projected_amount) &&
          exact_amount == {
            "numerator" => projection.fetch(:exact_amount).numerator.to_s,
            "denominator" => projection.fetch(:exact_amount).denominator.to_s
          }
      end

      def component_with_exact_source(raw_component, diagnostic_component, unit: false, origin: false)
        raw_component = normalized_hash(raw_component)
        diagnostic_component = normalized_hash(diagnostic_component)
        component = {
          "amount" => raw_component["amount"],
          "evidence" => diagnostic_component["evidence"]
        }
        component["unit_code"] = raw_component["unit_code"] if unit
        component["origin"] = raw_component["origin"] if origin
        component
      end

      def projection_for(candidate)
        ReceiptAmountService.reference_item_extension_projection(
          reference_price_amount: candidate.dig("reference_price", "amount"),
          reference_quantity: candidate.dig("reference_quantity", "amount"),
          reference_unit_code: candidate.dig("reference_quantity", "unit_code"),
          purchased_quantity: candidate.dig("purchased_quantity", "amount"),
          purchased_unit_code: candidate.dig("purchased_quantity", "unit_code")
        )
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def fixed_shape?(proposal)
        exact_keys?(proposal, ROOT_KEYS) &&
          proposal["schema_version"] == SCHEMA_VERSION &&
          proposal["creation_stage"] == CREATION_STAGE &&
          proposal["source_kind"] == SOURCE_KIND &&
          proposal["provider_model_id"] == PROVIDER_MODEL_ID &&
          proposal["provider_api_version"] == PROVIDER_API_VERSION &&
          STRING_INDEX_TYPES.include?(proposal["string_index_type"]) &&
          bounded_string?(proposal["candidate_id"], max_bytes: 128, pattern: CANDIDATE_ID_PATTERN) &&
          proposal["validation_state"] == "valid" &&
          proposal["validation_contract_version"] == VALIDATION_CONTRACT_VERSION &&
          proposal["analysis_profile_country_code"] == ANALYSIS_PROFILE_COUNTRY_CODE &&
          bounded_string?(
            proposal["integrity_checksum"],
            max_bytes: 64,
            pattern: INTEGRITY_CHECKSUM_PATTERN
          ) &&
          exact_keys?(proposal["destination"], DESTINATION_KEYS) &&
          destination_shape_valid?(proposal["destination"]) &&
          exact_keys?(proposal.dig("destination", "evidence"), DESTINATION_EVIDENCE_KEYS) &&
          word_spans_shape?(proposal.dig("destination", "evidence", "word_spans"), maximum: MAX_NAME_WORDS) &&
          word_spans_shape?(
            proposal.dig("destination", "evidence", "tax_word_spans"),
            exact_count: TAX_WORD_COUNT
          ) &&
          exact_keys?(proposal["block_span"], BLOCK_SPAN_KEYS) &&
          exact_keys?(proposal["reference_price"], PRICE_KEYS) &&
          exact_keys?(proposal["reference_quantity"], REFERENCE_QUANTITY_KEYS) &&
          exact_keys?(proposal["purchased_quantity"], PURCHASED_QUANTITY_KEYS) &&
          exact_keys?(proposal["tax_inclusion_evidence"], EVIDENCE_KEYS) &&
          exact_keys?(proposal["corroboration"], CORROBORATION_KEYS)
      end

      def source_fields_valid?(proposal)
        return false unless proposal["reference_price_tax_inclusion"] == "gross"
        return false unless proposal.dig("reference_quantity", "origin") == "explicit"
        return false unless exact_decimal?(proposal.dig("reference_price", "amount"))
        return false unless exact_decimal?(proposal.dig("reference_quantity", "amount"))
        return false unless exact_decimal?(proposal.dig("purchased_quantity", "amount"))
        return false unless ReceiptQuantityUnit.allowed_codes.include?(proposal.dig("reference_quantity", "unit_code"))
        return false unless ReceiptQuantityUnit.allowed_codes.include?(proposal.dig("purchased_quantity", "unit_code"))
        destination = proposal["destination"]
        reference_path = "pages[0].lines[#{destination["reference_line_index"]}]"
        purchased_path = "pages[0].lines[#{destination["purchased_quantity_line_index"]}]"
        return false unless proposal["candidate_id"] ==
          "azure_line_group_p0_l#{destination["reference_line_index"]}_" \
            "l#{destination["purchased_quantity_line_index"]}_reference_pricing"
        return false unless evidence_valid?(
          proposal.dig("reference_price", "evidence"),
          expected_path: reference_path,
          index_type: proposal["string_index_type"]
        )
        return false unless evidence_valid?(
          proposal.dig("reference_quantity", "evidence"),
          expected_path: reference_path,
          index_type: proposal["string_index_type"]
        )
        return false unless evidence_valid?(
          proposal.dig("purchased_quantity", "evidence"),
          expected_path: purchased_path,
          index_type: proposal["string_index_type"]
        )
        return false unless evidence_valid?(
          proposal["tax_inclusion_evidence"],
          expected_path: reference_path,
          index_type: proposal["string_index_type"]
        )
        return false unless tax_words_match_evidence?(proposal)
        return false unless block_contains_evidence?(proposal)
        return false unless source_evidence_ordered?(proposal)
        return false unless corroboration_valid?(proposal["corroboration"])

        projection_for(proposal).present?
      end

      def context_valid?(context, proposal:)
        return false unless context["schema_version"] == OCR_RESULT_SCHEMA_VERSION
        return false unless context["success"] == true
        return false unless Array(context.dig("candidates", "items")).empty?
        return false unless candidate_counts_valid?(context)
        return false if truncation_conflict?(context)

        diagnostic = diagnostic_candidate(context)
        return false if diagnostic.nil?
        return false unless diagnostic_state_valid?(diagnostic, proposal:)
        return false unless proposal["candidate_id"] == diagnostic["candidate_id"]
        return false unless proposal["source_kind"] == diagnostic["source_kind"]
        return false unless proposal["provider_model_id"] == diagnostic["provider_model_id"]
        return false unless proposal["provider_api_version"] == diagnostic["provider_api_version"]
        return false unless proposal["string_index_type"] == diagnostic["string_index_type"]
        return false unless proposal["validation_contract_version"] == diagnostic["validation_contract_version"]
        return false unless proposal["analysis_profile_country_code"] == diagnostic["analysis_profile_country_code"]
        return false unless proposal["destination"] == diagnostic["destination_item_identity"]
        return false unless proposal["block_span"] == {
          "provider_span_start" => diagnostic["block_provider_span_start"],
          "provider_span_end" => diagnostic["block_provider_span_end"]
        }
        return false unless proposal.dig("reference_price", "evidence") == diagnostic.dig("reference_price", "evidence")
        return false unless proposal.dig("reference_quantity", "evidence") == diagnostic.dig("reference_quantity", "evidence")
        return false unless proposal.dig("purchased_quantity", "evidence") == diagnostic.dig("purchased_quantity", "evidence")
        return false unless proposal["tax_inclusion_evidence"] == diagnostic["tax_inclusion_evidence"]
        return false unless proposal["corroboration"] == diagnostic["summary_total_corroboration"]

        destination_line_linked?(context, proposal["destination"])
      end

      def diagnostic_state_valid?(diagnostic, proposal:)
        return false unless diagnostic["validation_state"] == "valid"
        return false unless Array(diagnostic["rejection_reasons"]).empty?
        return false unless diagnostic["printed_line_total"].nil? && diagnostic["corroboration"].nil?
        return false unless diagnostic["reference_price_tax_inclusion"] == "gross"

        normalized_hash(diagnostic["summary_total_corroboration"]) == proposal["corroboration"]
      end

      def candidate_counts_valid?(context)
        counts = normalized_hash(context.dig("candidate_counts", "reference_pricing_candidates"))
        counts["actual_count"] == 1 && counts["snapshot_count"] == 1 &&
          Array(context.dig("candidates", "reference_pricing_candidates")).one?
      end

      def truncation_conflict?(context)
        truncated = normalized_hash(context["truncated"])
        %w[lines case_preserved_lines reference_pricing_candidates items].any? do |key|
          truncated[key] == true
        end
      end

      def diagnostic_candidate(context)
        candidates = Array(normalized_hash(context)["candidates"]&.dig("reference_pricing_candidates"))
        return nil unless candidates.one?

        normalized_hash(candidates.sole)
      end

      def destination_line_linked?(context, destination)
        destination = normalized_hash(destination)
        line_index = destination["name_line_index"]
        name_length = destination["normalized_name_grapheme_length"]
        return false unless line_index.is_a?(Integer) && line_index.between?(0, MAX_LINE_INDEX)
        return false unless name_length.is_a?(Integer) && name_length.between?(3, 24)

        line = Array(context["case_preserved_lines"])[line_index]
        return false unless safe_string?(line, max_bytes: 500)

        graphemes = line.scan(/\X/)
        name = graphemes.first(name_length).join
        separator = graphemes[name_length]
        profile = ReceiptAnalysisProfiles.fetch(ANALYSIS_PROFILE_COUNTRY_CODE)
        return false if profile.nil?

        name.present? && name.bytesize <= 96 && name.unicode_normalize(:nfkc) == name &&
          separator&.match?(/\A\p{Zs}\z/u) &&
          name.match?(profile.ocr_reference_pricing_line_group_identifier_pattern) &&
          name.match?(/[\p{L}\p{N}]\z/u) &&
          profile.ocr_reference_pricing_line_group_destination_identifier_conflict_patterns.none? do |pattern|
            name.match?(pattern)
          end && destination_name_unique?(name, lines: context["case_preserved_lines"])
      rescue EncodingError, ArgumentError
        false
      end

      def source_lines_lossless?(source_lines, context:, destination:)
        destination = normalized_hash(destination)
        line_indexes = %w[name_line_index reference_line_index purchased_quantity_line_index]
          .filter_map { |key| destination[key] }
          .uniq
        return false unless line_indexes.size == 2

        line_indexes.all? do |line_index|
          next false unless line_index.is_a?(Integer)

          source_line = Array(source_lines)[line_index]
          stored_line = Array(context["case_preserved_lines"])[line_index]
          source_line.is_a?(String) && source_line == stored_line
        end
      end

      def destination_name_unique?(name, lines:)
        occurrence_count = Array(lines).sum do |line|
          line.scan(Regexp.new(Regexp.escape(name))).size
        end
        occurrence_count == 1
      rescue EncodingError, ArgumentError, TypeError
        false
      end

      def destination_line_indexes(destination)
        indexes = %w[name_line_index reference_line_index purchased_quantity_line_index]
          .filter_map { |key| destination[key] }
          .uniq
          .sort
        indexes if indexes.size == 2 && indexes.all? { |index| index.is_a?(Integer) }
      rescue ArgumentError, TypeError
        nil
      end

      def destination_shape_valid?(destination)
        destination = normalized_hash(destination)
        evidence = normalized_hash(destination["evidence"])
        return false unless destination["contract_version"] == DESTINATION_CONTRACT_VERSION
        return false unless destination["kind"] == DESTINATION_KIND
        return false unless bounded_string?(destination["identity"], max_bytes: MAX_ID_BYTES, pattern: DESTINATION_ID_PATTERN)
        return false unless destination["page_index"] == 0
        return false unless destination["name_line_index"] == destination["reference_line_index"]
        return false unless destination["purchased_quantity_line_index"] == destination["reference_line_index"] + 1
        expected_identity = "azure_line_group_destination_p0_name_l#{destination["name_line_index"]}_" \
          "s#{evidence["provider_span_start"]}_e#{evidence["provider_span_end"]}_" \
          "ref_l#{destination["reference_line_index"]}_qty_l#{destination["purchased_quantity_line_index"]}"
        return false unless destination["identity"] == expected_identity
        return false unless evidence["source_provider"] == SOURCE_KIND
        return false unless evidence["page_index"] == 0 && evidence["line_index"] == destination["name_line_index"]
        return false unless evidence["string_index_type"].in?(STRING_INDEX_TYPES)
        return false unless bounded_string?(evidence["source_field_path"], max_bytes: MAX_PATH_BYTES, pattern: LINE_PATH_PATTERN)
        return false unless evidence["source_field_path"] == "pages[0].lines[#{destination["name_line_index"]}]"
        return false unless bounded_span?(evidence)

        exact_word_coverage?(evidence["word_spans"], evidence) &&
          word_spans_ordered?(evidence["tax_word_spans"])
      end

      def evidence_valid?(evidence, expected_path:, index_type:)
        evidence = normalized_hash(evidence)
        exact_keys?(evidence, EVIDENCE_KEYS) &&
          evidence["source_provider"] == SOURCE_KIND &&
          bounded_string?(evidence["source_field_path"], max_bytes: MAX_PATH_BYTES, pattern: LINE_PATH_PATTERN) &&
          evidence["source_field_path"] == expected_path &&
          evidence["string_index_type"] == index_type &&
          bounded_span?(evidence)
      end

      def block_contains_evidence?(proposal)
        block = normalized_hash(proposal["block_span"])
        return false unless bounded_span?(block)

        start_offset = block["provider_span_start"]
        end_offset = block["provider_span_end"]
        evidences = [
          proposal.dig("reference_price", "evidence"),
          proposal.dig("reference_quantity", "evidence"),
          proposal.dig("purchased_quantity", "evidence"),
          proposal["tax_inclusion_evidence"],
          proposal.dig("destination", "evidence")
        ]
        evidences.all? do |value|
          evidence = normalized_hash(value)
          evidence["provider_span_start"] >= start_offset &&
            evidence["provider_span_end"] <= end_offset
        end
      end

      def source_evidence_ordered?(proposal)
        destination = proposal.dig("destination", "evidence")
        tax = proposal["tax_inclusion_evidence"]
        price = proposal.dig("reference_price", "evidence")
        reference_quantity = proposal.dig("reference_quantity", "evidence")
        purchased_quantity = proposal.dig("purchased_quantity", "evidence")

        destination["provider_span_end"] < tax["provider_span_start"] &&
          tax["provider_span_end"] <= price["provider_span_start"] &&
          price["provider_span_end"] <= reference_quantity["provider_span_start"] &&
          reference_quantity["provider_span_end"] < purchased_quantity["provider_span_start"]
      end

      def tax_words_match_evidence?(proposal)
        word_spans = Array(proposal.dig("destination", "evidence", "tax_word_spans"))
          .map { |span| normalized_hash(span) }
        tax_evidence = normalized_hash(proposal["tax_inclusion_evidence"])
        word_spans.size == TAX_WORD_COUNT &&
          word_spans.first["provider_span_start"] == tax_evidence["provider_span_start"] &&
          word_spans.last["provider_span_end"] == tax_evidence["provider_span_end"] &&
          word_spans.each_cons(2).all? do |left, right|
            left["provider_span_end"] == right["provider_span_start"]
          end
      end

      def corroboration_valid?(value)
        corroboration = normalized_hash(value)
        matches = corroboration["rounding_matches"]
        corroboration["state"] == "matched" && matches.is_a?(Array) && matches.any? &&
          matches.uniq == matches && (matches - ROUNDING_MATCHES).empty?
      end

      def word_spans_shape?(value, maximum: nil, exact_count: nil)
        spans = value
        return false unless spans.is_a?(Array)
        return false if maximum && !spans.size.between?(1, maximum)
        return false if exact_count && spans.size != exact_count

        spans.all? do |span|
          normalized_span = normalized_hash(span)
          exact_keys?(span, WORD_SPAN_KEYS) &&
            bounded_string?(normalized_span["source_field_path"], max_bytes: MAX_PATH_BYTES, pattern: WORD_PATH_PATTERN) &&
            normalized_span["word_index"].is_a?(Integer) &&
            normalized_span["word_index"].between?(0, MAX_WORD_INDEX) &&
            normalized_span["source_field_path"] == "pages[0].words[#{normalized_span["word_index"]}]" &&
            bounded_span?(span)
        end && word_spans_ordered?(spans)
      end

      def exact_word_coverage?(spans, evidence)
        spans = Array(spans).map { |span| normalized_hash(span) }
        evidence = normalized_hash(evidence)
        spans.first["provider_span_start"] == evidence["provider_span_start"] &&
          spans.last["provider_span_end"] == evidence["provider_span_end"] &&
          spans.each_cons(2).all? { |left, right| left["provider_span_end"] == right["provider_span_start"] }
      end

      def word_spans_ordered?(value)
        spans = Array(value).map { |span| normalized_hash(span) }
        spans.each_cons(2).all? do |left, right|
          left["word_index"] < right["word_index"] &&
            left["provider_span_end"] <= right["provider_span_start"]
        end
      end

      def exact_keys?(value, expected)
        hash = normalized_hash(value)
        hash.present? && hash.keys.sort == expected.sort
      end

      def exact_decimal?(value)
        safe_string?(value, max_bytes: MAX_EXACT_NUMBER_BYTES) && value.match?(EXACT_DECIMAL_PATTERN)
      end

      def integrity_valid?(proposal, context:)
        expected = integrity_checksum(proposal, context:)
        return false if expected.nil?

        ActiveSupport::SecurityUtils.secure_compare(
          proposal["integrity_checksum"],
          expected
        )
      rescue ArgumentError, TypeError
        false
      end

      def integrity_checksum(proposal, context:)
        context_lines = integrity_context_lines(proposal, context:)
        return if context_lines.nil?

        proposal_payload = ROOT_KEYS.reject { |key| key == "integrity_checksum" }.to_h do |key|
          [ key, proposal[key] ]
        end
        payload = {
          "proposal" => proposal_payload,
          "context_lines" => context_lines
        }
        Digest::SHA256.hexdigest(JSON.generate(deep_canonical_value(payload)))
      end

      def integrity_context_lines(proposal, context:)
        destination = normalized_hash(proposal["destination"])
        line_indexes = destination_line_indexes(destination)
        return if line_indexes.nil?

        lines = context["case_preserved_lines"]
        line_indexes.map do |line_index|
          line = lines[line_index]
          return unless safe_string?(line, max_bytes: MAX_CONTEXT_LINE_BYTES)

          { "line_index" => line_index, "content" => line }
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

      def bounded_span?(value)
        value = normalized_hash(value)
        start_offset = value["provider_span_start"]
        end_offset = value["provider_span_end"]
        start_offset.is_a?(Integer) && end_offset.is_a?(Integer) &&
          start_offset.between?(0, MAX_PROVIDER_SPAN) &&
          end_offset.between?(1, MAX_PROVIDER_SPAN) && end_offset > start_offset
      end

      def bounded_string?(value, max_bytes:, pattern: nil)
        safe_string?(value, max_bytes:) && (!pattern || value.match?(pattern))
      end

      def safe_string?(value, max_bytes:)
        value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, max_bytes) &&
          !value.match?(CONTROL_CHARACTER_PATTERN)
      rescue ArgumentError, Encoding::CompatibilityError
        false
      end

      def serialized_within_bound?(proposal)
        JSON.generate(proposal).bytesize <= MAX_SERIALIZED_BYTES
      end

      def adoption_context(value)
        return unless value.is_a?(Hash)

        schema_version = context_hash_value(value, "schema_version", maximum_entries: 24)
        success = context_hash_value(value, "success", maximum_entries: 24)
        candidates = context_hash_value(value, "candidates", maximum_entries: 24)
        candidate_counts = context_hash_value(value, "candidate_counts", maximum_entries: 24)
        truncated = context_hash_value(value, "truncated", maximum_entries: 24)
        lines = context_hash_value(value, "case_preserved_lines", maximum_entries: 24)
        return unless candidates.is_a?(Hash) && candidate_counts.is_a?(Hash) && truncated.is_a?(Hash)
        return unless lines.is_a?(Array) && lines.size <= MAX_CONTEXT_LINES
        return unless lines.all? { |line| safe_context_line?(line) }

        items = context_hash_value(candidates, "items", maximum_entries: 32)
        reference_candidates = context_hash_value(
          candidates,
          "reference_pricing_candidates",
          maximum_entries: 32
        )
        reference_counts = context_hash_value(
          candidate_counts,
          "reference_pricing_candidates",
          maximum_entries: 16
        )
        return unless items.is_a?(Array) && items.empty?
        return unless reference_candidates.is_a?(Array) && reference_candidates.one?

        diagnostic = bounded_normalized_hash(reference_candidates.sole)
        counts = bounded_normalized_hash(reference_counts)
        return if diagnostic.nil? || counts.nil?

        truncation = %w[lines case_preserved_lines reference_pricing_candidates items].to_h do |key|
          raw = context_hash_value(truncated, key, maximum_entries: 16)
          return unless raw == true || raw == false

          [ key, raw ]
        end

        {
          "schema_version" => schema_version,
          "success" => success,
          "case_preserved_lines" => lines.map(&:dup),
          "candidates" => {
            "items" => [],
            "reference_pricing_candidates" => [ diagnostic ]
          },
          "candidate_counts" => { "reference_pricing_candidates" => counts },
          "truncated" => truncation
        }
      rescue EncodingError, ArgumentError, KeyError, TypeError
        nil
      end

      def context_hash_value(hash, expected_key, maximum_entries:)
        return unless hash.is_a?(Hash) && hash.size <= maximum_entries

        matching_keys = hash.keys.select do |key|
          (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s == expected_key
        end
        return unless matching_keys.one?

        hash[matching_keys.sole]
      end

      def bounded_normalized_hash(value)
        state = { nodes: 0 }
        normalized = bounded_normalized_value(value, depth: 0, state:)
        normalized if normalized.is_a?(Hash)
      rescue EncodingError, ArgumentError, SystemStackError, TypeError
        nil
      end

      def safe_context_line?(value)
        value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_CONTEXT_LINE_BYTES &&
          !value.match?(CONTROL_CHARACTER_PATTERN)
      rescue ArgumentError, Encoding::CompatibilityError
        false
      end

      def bounded_normalized_value(value, depth:, state:)
        return if depth > MAX_NORMALIZED_DEPTH

        state[:nodes] += 1
        return if state[:nodes] > MAX_NORMALIZED_NODES

        case value
        when Hash
          return if value.size > MAX_NORMALIZED_COLLECTION_SIZE

          normalized = {}
          value.each do |key, child|
            return unless key.is_a?(String) || key.is_a?(Symbol)

            normalized_key = key.to_s
            return unless safe_string?(normalized_key, max_bytes: 64)
            return if normalized.key?(normalized_key)

            normalized_child = bounded_normalized_value(child, depth: depth + 1, state:)
            return if normalized_child.nil? && !child.nil?

            normalized[normalized_key] = normalized_child
          end
          normalized
        when Array
          return if value.size > MAX_NORMALIZED_COLLECTION_SIZE

          normalized = value.map do |child|
            normalized_child = bounded_normalized_value(child, depth: depth + 1, state:)
            return if normalized_child.nil? && !child.nil?

            normalized_child
          end
          normalized
        when String
          value.dup if safe_string?(value, max_bytes: MAX_NORMALIZED_STRING_BYTES)
        when Integer, TrueClass, FalseClass, NilClass
          value
        end
      end

      def normalized_hash(value)
        return value if value.is_a?(Hash)

        {}
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
