# frozen_string_literal: true

require "bigdecimal"

module GeneratedReceipts
  module AdoptionEvidence
    class Comparator
      Result = Struct.new(:case_id, :status, :diffs, :metrics, keyword_init: true) do
        def pass?
          status == "PASS"
        end
      end

      SAFE_CANDIDATE_KEYS = Validator::CANDIDATE_KEYS.freeze
      SAFE_ASSOCIATION_KEYS = Validator::ASSOCIATION_KEYS.freeze
      CANDIDATE_LIMIT = Validator::MAX_COLLECTION_ITEMS
      SENSITIVE_CANDIDATE_VALUE_KEYS = %w[
        reference_price_amount
        reference_quantity
        purchased_quantity
        projected_line_total
        printed_line_total
      ].freeze
      REDACTED_DIFF_VALUE = "[redacted]".freeze
      GENERIC_INPUT_DIFF = {
        path: "comparison_input",
        expected: "bounded candidate summary and association map",
        actual: "malformed offline comparison input",
        severity: "FAIL"
      }.freeze

      class << self
        def call(case_data, candidate_summary:, associations:)
          new(
            case_data,
            candidate_summary: candidate_summary,
            associations: associations
          ).call
        rescue StandardError
          Result.new(
            case_id: safe_case_id(case_data),
            status: "FAIL",
            diffs: [ GENERIC_INPUT_DIFF.dup ],
            metrics: empty_metrics
          )
        end

        def empty_metrics
          {
            total_items: 0,
            reference_pricing_items: 0,
            candidate_extracted: 0,
            valid: 0,
            ambiguous: 0,
            unsupported: 0,
            missing: 0,
            false_association: 0,
            package_false_positive: 0,
            tax_basis_determined: 0,
            no_total_eligible_candidates: 0
          }
        end

        private

        def safe_case_id(value)
          return unless value.is_a?(Hash)

          case_id = value["case_id"]
          case_id if Validator.valid_case_id?(case_id)
        end
      end

      def initialize(case_data, candidate_summary:, associations:)
        @case_data = case_data
        @candidate_input = candidate_summary
        @association_input = associations
      end

      def call
        validation = Validator.call(case_data)
        return malformed_result unless validation.valid?

        actual_candidates = normalize_candidates(candidate_input)
        actual_associations = normalize_associations(association_input, actual_candidates)
        return malformed_result unless actual_candidates && actual_associations

        expected_candidates = case_data.dig("ground_truth", "expected_candidates")
        expected_associations = case_data.dig("ground_truth", "expected_associations")
        diffs = []
        compare_candidates(expected_candidates, actual_candidates, diffs)
        compare_associations(expected_associations, actual_associations, diffs)

        Result.new(
          case_id: case_data["case_id"],
          status: diffs.empty? ? "PASS" : "FAIL",
          diffs: diffs,
          metrics: build_metrics(
            actual_candidates,
            actual_associations,
            expected_associations,
            confirmed_match: diffs.empty?
          )
        )
      rescue StandardError
        malformed_result
      end

      private

      attr_reader :case_data, :candidate_input, :association_input

      def malformed_result
        Result.new(
          case_id: safe_case_id,
          status: "FAIL",
          diffs: [ GENERIC_INPUT_DIFF.dup ],
          metrics: self.class.empty_metrics
        )
      end

      def safe_case_id
        value = case_data["case_id"] if case_data.is_a?(Hash)
        value if Validator.valid_case_id?(value)
      end

      def normalize_candidates(value)
        return unless value.is_a?(Array) && value.size <= CANDIDATE_LIMIT
        return unless value.all? do |entry|
          entry.is_a?(Hash) &&
            entry.keys.all? { |key| key.is_a?(String) } &&
            entry.keys.sort == SAFE_CANDIDATE_KEYS.sort
        end

        summaries = GeneratedReceipts::Comparator.reference_pricing_candidates_summary(value)
        return unless summaries.size == value.size

        summaries.map do |summary|
          return unless summary.is_a?(Hash)
          return if summary["validation_state"] == "malformed"

          normalized = SAFE_CANDIDATE_KEYS.to_h { |key| [ key, summary[key] ] }
          return unless valid_normalized_candidate?(normalized)

          normalized
        end
      rescue StandardError
        nil
      end

      def valid_normalized_candidate?(candidate)
        probe = {
          "case_id" => case_data["case_id"],
          "intent" => case_data["intent"],
          "expected" => {},
          "render" => case_data["render"],
          "degradation" => case_data["degradation"],
          "ground_truth" => {
            "defined_before_image_generation" => true,
            "items" => case_data.dig("ground_truth", "items"),
            "expected_candidates" => [ candidate ],
            "expected_associations" => [
              {
                "candidate_index" => 0,
                "item_index" => candidate["item_index"],
                "evidence_scope" => "same_item"
              }
            ]
          }
        }
        structural_errors = Validator.call(probe).errors
        structural_errors.none? do |error|
          error.start_with?("ground_truth.expected_candidates[0]") &&
            !error.include?("printed_line_total: must match the ground-truth item")
        end
      end

      def normalize_associations(value, candidates)
        return unless value.is_a?(Array) && value.size <= CANDIDATE_LIMIT

        normalized = value.map do |entry|
          return unless entry.is_a?(Hash) && entry.keys.all? { |key| key.is_a?(String) }
          return unless (entry.keys - SAFE_ASSOCIATION_KEYS).empty?
          return unless (SAFE_ASSOCIATION_KEYS - entry.keys).empty?

          candidate_index = entry["candidate_index"]
          item_index = entry["item_index"]
          scope = entry["evidence_scope"]
          return unless candidate_index.is_a?(Integer) && candidate_index.between?(0, candidates.size - 1)
          return unless item_index.is_a?(Integer) && item_index.between?(0, Validator::MAX_ITEM_INDEX)
          return unless Validator::EVIDENCE_SCOPES.include?(scope)
          return unless candidates[candidate_index]["item_index"] == item_index
          ground_truth_item_indexes = case_data.dig("ground_truth", "items").map { |item| item["item_index"] }
          return unless ground_truth_item_indexes.include?(item_index)

          {
            "candidate_index" => candidate_index,
            "item_index" => item_index,
            "evidence_scope" => scope
          }
        end
        indexes = normalized.map { |entry| entry["candidate_index"] }
        return unless indexes.sort == (0...candidates.size).to_a

        normalized.sort_by { |entry| entry["candidate_index"] }
      rescue StandardError
        nil
      end

      def compare_candidates(expected, actual, diffs)
        if expected.size != actual.size
          add_diff(
            diffs,
            path: "candidate_summary.count",
            expected: expected.size,
            actual: actual.size
          )
        end
        [ expected.size, actual.size ].min.times do |index|
          SAFE_CANDIDATE_KEYS.each do |key|
            next if expected[index][key] == actual[index][key]

            add_diff(
              diffs,
              path: "candidate_summary[#{index}].#{key}",
              expected: expected[index][key],
              actual: actual[index][key],
              redact_values: SENSITIVE_CANDIDATE_VALUE_KEYS.include?(key)
            )
          end
        end
      end

      def compare_associations(expected, actual, diffs)
        if expected.size != actual.size
          add_diff(
            diffs,
            path: "associations.count",
            expected: expected.size,
            actual: actual.size
          )
        end
        [ expected.size, actual.size ].min.times do |index|
          SAFE_ASSOCIATION_KEYS.each do |key|
            next if expected[index][key] == actual[index][key]

            add_diff(
              diffs,
              path: "associations[#{index}].#{key}",
              expected: expected[index][key],
              actual: actual[index][key]
            )
          end
        end
      end

      def add_diff(diffs, path:, expected:, actual:, redact_values: false)
        expected_value = redact_values ? REDACTED_DIFF_VALUE : safe_diff_value(expected)
        actual_value = redact_values ? REDACTED_DIFF_VALUE : safe_diff_value(actual)
        diffs << {
          path: path,
          expected: expected_value,
          actual: actual_value,
          severity: "FAIL"
        }
      end

      def safe_diff_value(value)
        case value
        when nil, true, false, Integer
          value
        when String
          return "[invalid]" if value.bytesize > Validator::MAX_TOKEN_BYTES
          return "[invalid]" unless value.valid_encoding? && !value.match?(Validator::CONTROL_PATTERN)

          value
        when Array
          return "[invalid]" if value.size > GeneratedReceipts::Validator::MAX_REJECTION_REASONS
          return "[invalid]" unless value.all? { |entry| entry.is_a?(String) && entry.bytesize <= Validator::MAX_TOKEN_BYTES }

          value.dup
        else
          "[invalid]"
        end
      rescue EncodingError
        "[invalid]"
      end

      def build_metrics(candidates, associations, expected_associations, confirmed_match:)
        items = case_data.dig("ground_truth", "items")
        states = candidates.map { |candidate| candidate["validation_state"] }
        expected_pairs = expected_associations.map { |entry| association_pair(entry) }
        actual_pairs = associations.map { |entry| association_pair(entry) }

        self.class.empty_metrics.merge(
          total_items: items.size,
          reference_pricing_items: items.count { |item| item["evidence_class"] == "reference_pricing" },
          candidate_extracted: candidates.size,
          valid: states.count("valid"),
          ambiguous: states.count("ambiguous"),
          unsupported: states.count("unsupported"),
          missing: states.count("missing"),
          false_association: (actual_pairs - expected_pairs).size,
          package_false_positive: package_false_positive_count(candidates, associations, items),
          tax_basis_determined: candidates.count do |candidate|
            %w[gross net].include?(candidate["reference_price_tax_inclusion"])
          end,
          no_total_eligible_candidates: confirmed_match ?
            no_total_eligible_count(candidates, associations, items) : 0
        )
      end

      def association_pair(entry)
        [ entry["candidate_index"], entry["item_index"], entry["evidence_scope"] ]
      end

      def package_false_positive_count(candidates, associations, items)
        package_indexes = items.filter_map do |item|
          item["item_index"] if item["evidence_class"] == "package_content"
        end
        associations.count do |association|
          package_indexes.include?(association["item_index"]) &&
            candidates[association["candidate_index"]]
        end
      end

      def no_total_eligible_count(candidates, associations, items)
        items.count do |item|
          item_candidates = candidates.select { |candidate| candidate["item_index"] == item["item_index"] }
          association = associations.find do |entry|
            entry["item_index"] == item["item_index"] && entry["evidence_scope"] == "same_item"
          end
          actual_candidate_eligible?(item, item_candidates, association)
        end
      end

      def actual_candidate_eligible?(item, candidates, association)
        return false unless item["evidence_class"] == "reference_pricing"
        return false unless item["printed_line_total"].nil? && !item["existing_authority"]
        return false unless candidates.one? && association

        candidate = candidates.first
        return false unless candidate["printed_line_total"].nil?
        return false unless candidate["validation_state"] == "valid"
        return false unless item["same_item_evidence"]
        return false unless reference_components_complete?(candidate)
        return false unless purchased_components_complete?(candidate)
        return false unless %w[gross net].include?(candidate["reference_price_tax_inclusion"])
        if candidate["reference_price_tax_inclusion"] == "net"
          return false unless valid_tax_rate?(item["item_local_tax_rate"])
          return false if item["tax_rate_conflict"]
        end
        return false if item["package_conflict"] || item["discount_conflict"]
        projection = actual_projection(candidate, item)
        return false unless projection
        return false unless projection.projected_reference_line_total == candidate["projected_line_total"]

        !projection.projected_gross_line_total.nil?
      end

      def actual_projection(candidate, item)
        MeasurementContract.project(
          source_item: {
            "reference_price_amount" => candidate["reference_price_amount"],
            "reference_quantity" => candidate["reference_quantity"],
            "reference_unit" => candidate["reference_unit_code"],
            "purchased_quantity" => candidate["purchased_quantity"],
            "purchased_unit" => candidate["purchased_unit_code"],
            "reference_price_tax_inclusion" => candidate["reference_price_tax_inclusion"]
          },
          tax_rate: item["item_local_tax_rate"],
          tax_rounding: item["tax_rounding_mode"],
          discount_rounding: "round"
        )
      rescue ArgumentError, TypeError, ZeroDivisionError, FloatDomainError, RangeError
        nil
      end

      def reference_components_complete?(candidate)
        %w[reference_price_amount reference_quantity reference_unit_code].all? do |field|
          !candidate[field].nil?
        end
      end

      def purchased_components_complete?(candidate)
        %w[purchased_quantity purchased_unit_code].all? { |field| !candidate[field].nil? }
      end

      def valid_tax_rate?(value)
        return false unless value.is_a?(String) && value.match?(Validator::DECIMAL_PATTERN)

        decimal = BigDecimal(value)
        decimal >= 0 && decimal <= 1
      rescue ArgumentError, TypeError, FloatDomainError
        false
      end
    end
  end
end
