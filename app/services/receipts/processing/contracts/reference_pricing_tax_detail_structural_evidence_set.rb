require "bigdecimal"
require "digest"
require "json"

module Receipts::Processing::Contracts
  class ReferencePricingTaxDetailStructuralEvidenceSet
    SCHEMA_VERSION = "reference_pricing_tax_detail_structural_evidence_set_v1"
    CREATION_STAGE = "ocr_validation"
    SOURCE_PROVIDER = "azure_structured"
    PROVIDER_MODEL_ID = "prebuilt-receipt"
    PROVIDER_API_VERSION = "2024-11-30"
    OCR_RESULT_SCHEMA_VERSION = "receipt_analysis_run_ocr_result_v1"
    STRING_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze

    MAX_TAX_DETAILS = 20
    MAX_PARENT_SPANS = 16
    MAX_SERIALIZED_BYTES = 64 * 1_024
    MAX_PATH_BYTES = 256
    MAX_PROVIDER_SPAN = 10_000_000
    MAX_PAGE_INDEX = 7
    MAX_LINE_INDEX = 149
    MAX_AMOUNT = 999_999_999_999
    MAX_RATE_SCALE = 6
    MAX_NORMALIZED_NODES = 4_096
    MAX_NORMALIZED_DEPTH = 8
    MAX_NORMALIZED_COLLECTION_SIZE = 32
    MAX_NORMALIZED_STRING_BYTES = 512

    CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B\uFEFF\p{Bidi_Control}]/.freeze
    RATE_PATTERN = /\A(?:0|[1-9][0-9]*)(?:\.[0-9]*[1-9])?\z/.freeze
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/.freeze

    METADATA_KEYS = %w[
      source_provider provider_model_id provider_api_version string_index_type tax_details
    ].freeze
    ROOT_KEYS = (%w[schema_version creation_stage] + METADATA_KEYS + %w[integrity_checksum]).freeze
    TAX_DETAIL_KEYS = %w[tax_detail_index parent rate net_amount tax_amount].freeze
    PARENT_KEYS = %w[source_provider source_field_path tax_detail_index provider_spans].freeze
    PARENT_SPAN_KEYS = %w[provider_span_start provider_span_end].freeze
    RATE_KEYS = %w[
      source_provider source_field_path tax_detail_index page_index line_index string_index_type
      provider_span_start provider_span_end rate
    ].freeze
    AMOUNT_KEYS = %w[
      source_provider source_field_path tax_detail_index page_index line_index string_index_type
      provider_span_start provider_span_end amount
    ].freeze

    class << self
      def build(metadata:, ocr_snapshot:)
        metadata = bounded_normalized_hash(metadata)
        context = tax_detail_context(ocr_snapshot)
        return nil if metadata.nil? || context.nil?
        return nil unless exact_keys?(metadata, METADATA_KEYS)

        proposal = {
          "schema_version" => SCHEMA_VERSION,
          "creation_stage" => CREATION_STAGE,
          "source_provider" => metadata["source_provider"],
          "provider_model_id" => metadata["provider_model_id"],
          "provider_api_version" => metadata["provider_api_version"],
          "string_index_type" => metadata["string_index_type"],
          "tax_details" => metadata["tax_details"]
        }
        return nil unless proposal_valid?(proposal, context:)

        proposal["integrity_checksum"] = integrity_checksum(proposal, context:)
        from_snapshot(proposal, ocr_snapshot:)
      rescue ArgumentError, EncodingError, JSON::GeneratorError, KeyError, TypeError
        nil
      end

      def from_snapshot(value, ocr_snapshot:)
        proposal = bounded_normalized_hash(value)
        context = tax_detail_context(ocr_snapshot)
        return nil if proposal.nil? || context.nil?
        return nil unless exact_keys?(proposal, ROOT_KEYS)
        return nil unless proposal_valid?(proposal, context:)
        return nil unless serialized_within_bound?(proposal)
        return nil unless integrity_valid?(proposal, context:)

        deep_copy(proposal)
      rescue ArgumentError, EncodingError, JSON::GeneratorError, KeyError, TypeError
        nil
      end

      private

      def proposal_valid?(proposal, context:)
        return false unless proposal["schema_version"] == SCHEMA_VERSION
        return false unless proposal["creation_stage"] == CREATION_STAGE
        return false unless proposal["source_provider"] == SOURCE_PROVIDER
        return false unless proposal["provider_model_id"] == PROVIDER_MODEL_ID
        return false unless proposal["provider_api_version"] == PROVIDER_API_VERSION
        return false unless STRING_INDEX_TYPES.include?(proposal["string_index_type"])
        return false unless tax_details_valid?(proposal["tax_details"], proposal:)
        return false unless proposal_matches_context?(proposal, context:)
        return false unless serialized_within_bound?(proposal)

        checksum = proposal["integrity_checksum"]
        checksum.nil? || bounded_string?(checksum, maximum: 64, pattern: CHECKSUM_PATTERN)
      end

      def tax_details_valid?(value, proposal:)
        return false unless value.is_a?(Array) && value.size.between?(1, MAX_TAX_DETAILS)

        details = value.each_with_index.map do |detail, expected_index|
          return false unless tax_detail_valid?(detail, expected_index:, proposal:)

          detail
        end
        parent_spans = details.flat_map { |detail| detail.dig("parent", "provider_spans") }
        parent_spans.each_cons(2).all? do |left, right|
          left["provider_span_end"] <= right["provider_span_start"]
        end
      end

      def tax_detail_valid?(value, expected_index:, proposal:)
        return false unless exact_keys?(value, TAX_DETAIL_KEYS)
        return false unless value["tax_detail_index"] == expected_index

        parent = value["parent"]
        rate = value["rate"]
        net_amount = value["net_amount"]
        tax_amount = value["tax_amount"]
        return false unless parent_valid?(parent, expected_index:)
        return false unless rate_valid?(rate, expected_index:, proposal:, parent:)
        return false unless amount_valid?(net_amount, expected_index:, proposal:, parent:, positive: true, field: "NetAmount")
        return false unless amount_valid?(tax_amount, expected_index:, proposal:, parent:, positive: false, field: "Amount")

        child_spans = [ rate, net_amount, tax_amount ]
        child_spans.combination(2).none? { |left, right| spans_overlap?(left, right) }
      end

      def parent_valid?(value, expected_index:)
        return false unless exact_keys?(value, PARENT_KEYS)
        return false unless value["source_provider"] == SOURCE_PROVIDER
        return false unless value["tax_detail_index"] == expected_index
        return false unless bounded_string?(value["source_field_path"], maximum: MAX_PATH_BYTES)
        return false unless value["source_field_path"] == tax_detail_path(expected_index)

        spans = value["provider_spans"]
        spans.is_a?(Array) && spans.size.between?(1, MAX_PARENT_SPANS) &&
          spans.all? { |span| exact_keys?(span, PARENT_SPAN_KEYS) && bounded_span?(span) } &&
          spans.each_cons(2).all? do |left, right|
            left["provider_span_end"] <= right["provider_span_start"]
          end
      end

      def rate_valid?(value, expected_index:, proposal:, parent:)
        return false unless child_evidence_valid?(
          value,
          expected_keys: RATE_KEYS,
          expected_index:,
          proposal:,
          parent:,
          expected_path: "#{tax_detail_path(expected_index)}.Rate"
        )

        value["rate"].is_a?(String) && canonical_rate(value["rate"]) == value["rate"]
      end

      def amount_valid?(value, expected_index:, proposal:, parent:, positive:, field:)
        return false unless child_evidence_valid?(
          value,
          expected_keys: AMOUNT_KEYS,
          expected_index:,
          proposal:,
          parent:,
          expected_path: "#{tax_detail_path(expected_index)}.#{field}"
        )

        amount = value["amount"]
        amount.is_a?(Integer) && amount.between?(positive ? 1 : 0, MAX_AMOUNT)
      end

      def child_evidence_valid?(value, expected_keys:, expected_index:, proposal:, parent:, expected_path:)
        return false unless exact_keys?(value, expected_keys)
        return false unless value["source_provider"] == SOURCE_PROVIDER
        return false unless bounded_string?(value["source_field_path"], maximum: MAX_PATH_BYTES)
        return false unless value["source_field_path"] == expected_path
        return false unless value["tax_detail_index"] == expected_index
        return false unless value["page_index"].is_a?(Integer) && value["page_index"].between?(0, MAX_PAGE_INDEX)
        return false unless value["line_index"].is_a?(Integer) && value["line_index"].between?(0, MAX_LINE_INDEX)
        return false unless value["string_index_type"] == proposal["string_index_type"]
        return false unless bounded_span?(value)

        Array(parent["provider_spans"]).one? do |span|
          value["provider_span_start"] >= span["provider_span_start"] &&
            value["provider_span_end"] <= span["provider_span_end"]
        end
      end

      def proposal_matches_context?(proposal, context:)
        tax_details = proposal["tax_details"]
        return false unless tax_details.size == context.fetch("tax_details").size

        tax_details.each_with_index.all? do |detail, index|
          ordinary = context.fetch("tax_details")[index]
          detail.dig("rate", "rate") == ordinary.fetch("rate") &&
            detail.dig("net_amount", "amount") == ordinary.fetch("net_amount") &&
            detail.dig("tax_amount", "amount") == ordinary.fetch("amount")
        end
      end

      def tax_detail_context(value)
        return unless value.is_a?(Hash)

        schema_version = context_hash_value(value, "schema_version", maximum_entries: 32)
        candidates = context_hash_value(value, "candidates", maximum_entries: 32)
        candidate_counts = context_hash_value(value, "candidate_counts", maximum_entries: 32)
        truncated = context_hash_value(value, "truncated", maximum_entries: 32)
        return unless schema_version == OCR_RESULT_SCHEMA_VERSION
        return unless candidates.is_a?(Hash) && candidate_counts.is_a?(Hash) && truncated.is_a?(Hash)

        tax_details = context_hash_value(candidates, "tax_details", maximum_entries: 32)
        counts = context_hash_value(candidate_counts, "tax_details", maximum_entries: 32)
        tax_details_truncated = context_hash_value(truncated, "tax_details", maximum_entries: 32)
        return unless tax_details.is_a?(Array) && tax_details.size.between?(1, MAX_TAX_DETAILS)
        return unless counts.is_a?(Hash) && tax_details_truncated == false

        actual_count = context_hash_value(counts, "actual_count", maximum_entries: 8)
        snapshot_count = context_hash_value(counts, "snapshot_count", maximum_entries: 8)
        return unless actual_count == tax_details.size && snapshot_count == tax_details.size

        normalized_details = tax_details.map do |detail|
          normalized_ordinary_tax_detail(detail)
        end
        return if normalized_details.any?(&:nil?)

        {
          "schema_version" => schema_version,
          "tax_details" => normalized_details,
          "actual_count" => actual_count,
          "snapshot_count" => snapshot_count,
          "truncated" => false
        }
      rescue ArgumentError, EncodingError, TypeError
        nil
      end

      def normalized_ordinary_tax_detail(value)
        return unless value.is_a?(Hash)

        rate = context_hash_value(value, "rate", maximum_entries: 8)
        net_amount = context_hash_value(value, "net_amount", maximum_entries: 8)
        amount = context_hash_value(value, "amount", maximum_entries: 8)
        rate = canonical_rate(rate)
        net_amount = canonical_amount(net_amount, positive: true)
        amount = canonical_amount(amount, positive: false)
        return if rate.nil? || net_amount.nil? || amount.nil?

        { "rate" => rate, "net_amount" => net_amount, "amount" => amount }
      end

      def context_hash_value(hash, expected_key, maximum_entries:)
        return unless hash.is_a?(Hash) && hash.size <= maximum_entries

        matching_keys = hash.keys.select do |key|
          (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s == expected_key
        end
        return unless matching_keys.one?

        hash[matching_keys.sole]
      end

      def canonical_rate(value)
        return unless value.is_a?(Numeric) || bounded_string?(value, maximum: 64)
        return if value.respond_to?(:finite?) && !value.finite?

        text = value.to_s
        return unless bounded_string?(text, maximum: 64)

        rate = BigDecimal(text)
        return unless rate.positive? && rate <= 1

        text = rate.to_s("F").sub(/\.?0+\z/, "")
        scale = text.split(".", 2).fetch(1, "").length
        text if scale <= MAX_RATE_SCALE && text.match?(RATE_PATTERN)
      rescue ArgumentError
        nil
      end

      def canonical_amount(value, positive:)
        return unless value.is_a?(Numeric)
        return if value.respond_to?(:finite?) && !value.finite?

        text = value.to_s
        return unless bounded_string?(text, maximum: 64)

        amount = BigDecimal(text)
        return unless amount.frac.zero?

        integer = amount.to_i
        integer if integer.between?(positive ? 1 : 0, MAX_AMOUNT)
      rescue ArgumentError
        nil
      end

      def bounded_span?(value)
        start_offset = value["provider_span_start"]
        end_offset = value["provider_span_end"]
        start_offset.is_a?(Integer) && end_offset.is_a?(Integer) &&
          start_offset.between?(0, MAX_PROVIDER_SPAN) &&
          end_offset.between?(1, MAX_PROVIDER_SPAN) && end_offset > start_offset
      end

      def spans_overlap?(left, right)
        left["provider_span_start"] < right["provider_span_end"] &&
          right["provider_span_start"] < left["provider_span_end"]
      end

      def tax_detail_path(index)
        "documents[0].fields.TaxDetails[#{index}]"
      end

      def integrity_valid?(proposal, context:)
        actual = proposal["integrity_checksum"]
        return false unless bounded_string?(actual, maximum: 64, pattern: CHECKSUM_PATTERN)

        expected = integrity_checksum(proposal, context:)
        ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      rescue ArgumentError, TypeError
        false
      end

      def integrity_checksum(proposal, context:)
        payload = {
          "evidence_set" => ROOT_KEYS.reject { |key| key == "integrity_checksum" }.to_h do |key|
            [ key, proposal[key] ]
          end,
          "ocr_tax_detail_context" => context
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
