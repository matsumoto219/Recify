# frozen_string_literal: true

require "bigdecimal"
require "json"

module GeneratedReceipts
  module AdoptionEvidence
    class Validator
      class FixtureLoadError < StandardError; end

      Result = Struct.new(:case_id, :errors, keyword_init: true) do
        def valid?
          errors.empty?
        end
      end

      TOP_LEVEL_KEYS = %w[
        case_id
        intent
        expected
        render
        degradation
        ground_truth
      ].freeze
      GROUND_TRUTH_KEYS = %w[
        defined_before_image_generation
        items
        expected_candidates
        expected_associations
      ].freeze
      ITEM_KEYS = %w[
        item_index
        evidence_class
        printed_line_total
        existing_authority
        same_item_evidence
        dimension_compatible
        item_local_tax_rate
        tax_rounding_mode
        tax_rate_conflict
        package_conflict
        discount_conflict
        deterministic_projection
        projection_within_bounds
        projected_gross_line_total
        adoption_outcome
        adoption_blocking_reasons
      ].freeze
      CANDIDATE_KEYS = %w[
        item_index
        validation_state
        rejection_reasons
        reference_price_amount
        reference_quantity
        reference_unit_code
        purchased_quantity
        purchased_unit_code
        reference_price_tax_inclusion
        projected_line_total
        printed_line_total
        rounding_matches
      ].freeze
      ASSOCIATION_KEYS = %w[candidate_index item_index evidence_scope].freeze
      RENDER_KEYS = %w[locale paper_width font custom_lines noise_lines].freeze
      DEGRADATION_KEYS = %w[enabled profile].freeze

      EVIDENCE_CLASSES = %w[
        reference_pricing
        count_unit_price
        package_content
        discount
        other
      ].freeze
      CANDIDATE_STATES = %w[valid ambiguous unsupported missing].freeze
      TAX_INCLUSIONS = %w[gross net unknown].freeze
      ADOPTION_OUTCOMES = %w[eligible review unsupported].freeze
      EVIDENCE_SCOPES = %w[same_item outside_item].freeze
      BLOCKING_REASONS = %w[
        printed_total_present
        existing_authority_present
        candidate_count_not_one
        candidate_not_valid
        same_item_evidence_incomplete
        reference_components_incomplete
        purchased_components_incomplete
        dimension_incompatible
        item_local_tax_basis_missing
        item_local_tax_rate_missing_or_conflicting
        package_conflict
        discount_conflict
        deterministic_projection_unavailable
        projected_amount_out_of_bounds
      ].freeze

      MAX_COLLECTION_ITEMS = 100
      MAX_ITEM_INDEX = MAX_COLLECTION_ITEMS - 1
      MAX_CASE_FILE_BYTES = 4 * 1024 * 1024
      MAX_JSON_NESTING = 16
      MAX_CASE_ID_BYTES = 64
      MAX_TEXT_BYTES = 512
      MAX_SOURCE_LINES = 100
      MAX_ERRORS = 1_000
      MAX_TOKEN_BYTES = 64
      MAX_LINE_TOTAL = 999_999_999
      MAX_PRICE = BigDecimal("999999999999")
      MAX_QUANTITY = BigDecimal("9999.999")
      CASE_ID_PATTERN = /\Ag\d{3}_[a-z0-9_]+\z/.freeze
      DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
      CONTROL_PATTERN = /[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]/.freeze
      FIXTURE_LOAD_ERROR_MESSAGE = "adoption evidence fixture could not be loaded safely"

      class << self
        def call(value)
          new(value).call
        rescue StandardError
          case_id = value["case_id"] if value.is_a?(Hash) && valid_case_id?(value["case_id"])
          Result.new(case_id: case_id, errors: [ "evidence: could not be validated safely" ])
        end

        def load_file(path)
          fixture_path = safe_fixture_path(path)
          payload = File.open(fixture_path, "rb") { |file| file.read(MAX_CASE_FILE_BYTES + 1) }
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE if payload.nil? || payload.bytesize > MAX_CASE_FILE_BYTES

          payload.force_encoding(Encoding::UTF_8)
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE unless payload.valid_encoding?

          value = JSON.parse(payload, max_nesting: MAX_JSON_NESTING)
          unless value.is_a?(Hash) && valid_case_id?(value["case_id"]) &&
              value["case_id"] == File.basename(fixture_path, ".json")
            raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
          end

          value
        rescue FixtureLoadError
          raise
        rescue JSON::ParserError, EncodingError, SystemCallError, ArgumentError, TypeError
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end

        def valid_case_id?(value)
          value.is_a?(String) && value.bytesize.between?(1, MAX_CASE_ID_BYTES) &&
            value.valid_encoding? && value.ascii_only? && value.match?(CASE_ID_PATTERN)
        rescue EncodingError
          false
        end

        private

        def safe_fixture_path(path)
          candidate = File.expand_path(File.path(path))
          root = File.realpath(GeneratedReceipts::ADOPTION_EVIDENCE_CASES_DIR)
          stat = File.lstat(candidate)
          unless File.extname(candidate) == ".json" && stat.file? && !stat.symlink?
            raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
          end

          resolved = File.realpath(candidate)
          unless File.dirname(resolved) == root
            raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
          end

          resolved
        rescue FixtureLoadError
          raise
        rescue EncodingError, SystemCallError, ArgumentError, TypeError
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end
      end

      def initialize(value)
        @case_data = value
        @errors = []
      end

      def call
        validate_schema
        validate_contract if errors.empty?
        Result.new(case_id: safe_case_id, errors: errors)
      end

      private

      attr_reader :case_data, :errors

      def validate_schema
        validate_hash("case", case_data, required: TOP_LEVEL_KEYS, allowed: TOP_LEVEL_KEYS)
        return unless case_data.is_a?(Hash)

        add_error("case_id", "must be a path-safe generated case ID") unless self.class.valid_case_id?(case_data["case_id"])
        validate_text("intent", case_data["intent"])
        validate_empty_expected
        validate_render
        validate_degradation
        validate_ground_truth
      end

      def validate_empty_expected
        expected = case_data["expected"]
        validate_hash("expected", expected, required: [], allowed: [])
      end

      def validate_render
        render = case_data["render"]
        validate_hash("render", render, required: %w[custom_lines], allowed: RENDER_KEYS)
        return unless render.is_a?(Hash)

        validate_optional_text("render.locale", render["locale"])
        validate_optional_inclusion("render.paper_width", render["paper_width"], %w[58mm 80mm])
        validate_optional_text("render.font", render["font"])
        validate_text_array("render.custom_lines", render["custom_lines"], minimum: 1)
        validate_text_array("render.noise_lines", render["noise_lines"]) if render.key?("noise_lines")
      end

      def validate_degradation
        degradation = case_data["degradation"]
        validate_hash(
          "degradation",
          degradation,
          required: DEGRADATION_KEYS,
          allowed: DEGRADATION_KEYS
        )
        return unless degradation.is_a?(Hash)

        validate_boolean("degradation.enabled", degradation["enabled"])
        if degradation["enabled"] == true
          validate_inclusion(
            "degradation.profile",
            degradation["profile"],
            DegradationProfiles.names
          )
        elsif !degradation["profile"].nil?
          add_error("degradation.profile", "must be null when degradation is disabled")
        end
      end

      def validate_ground_truth
        ground_truth = case_data["ground_truth"]
        validate_hash(
          "ground_truth",
          ground_truth,
          required: GROUND_TRUTH_KEYS,
          allowed: GROUND_TRUTH_KEYS
        )
        return unless ground_truth.is_a?(Hash)

        unless ground_truth["defined_before_image_generation"] == true
          add_error(
            "ground_truth.defined_before_image_generation",
            "must be true before rendering or provider comparison"
          )
        end
        validate_items(ground_truth["items"])
        validate_candidates(ground_truth["expected_candidates"])
        validate_associations(ground_truth["expected_associations"])
      end

      def validate_items(value)
        validate_array("ground_truth.items", value, minimum: 1) do |item, index|
          path = "ground_truth.items[#{index}]"
          validate_hash(path, item, required: ITEM_KEYS, allowed: ITEM_KEYS)
          next unless item.is_a?(Hash)

          validate_item_index("#{path}.item_index", item["item_index"])
          validate_inclusion("#{path}.evidence_class", item["evidence_class"], EVIDENCE_CLASSES)
          validate_optional_line_total("#{path}.printed_line_total", item["printed_line_total"])
          %w[
            existing_authority
            same_item_evidence
            dimension_compatible
            tax_rate_conflict
            package_conflict
            discount_conflict
            deterministic_projection
            projection_within_bounds
          ].each do |field|
            validate_boolean("#{path}.#{field}", item[field])
          end
          validate_optional_tax_rate("#{path}.item_local_tax_rate", item["item_local_tax_rate"])
          validate_inclusion("#{path}.tax_rounding_mode", item["tax_rounding_mode"], GeneratedReceipts::Validator::ROUNDING_MODES)
          validate_optional_line_total("#{path}.projected_gross_line_total", item["projected_gross_line_total"])
          validate_inclusion("#{path}.adoption_outcome", item["adoption_outcome"], ADOPTION_OUTCOMES)
          validate_token_array(
            "#{path}.adoption_blocking_reasons",
            item["adoption_blocking_reasons"],
            allowed: BLOCKING_REASONS
          )
        end
      end

      def validate_candidates(value)
        validate_array("ground_truth.expected_candidates", value) do |candidate, index|
          path = "ground_truth.expected_candidates[#{index}]"
          validate_hash(path, candidate, required: CANDIDATE_KEYS, allowed: CANDIDATE_KEYS)
          next unless candidate.is_a?(Hash)

          validate_item_index("#{path}.item_index", candidate["item_index"])
          validate_inclusion("#{path}.validation_state", candidate["validation_state"], CANDIDATE_STATES)
          validate_token_array(
            "#{path}.rejection_reasons",
            candidate["rejection_reasons"],
            allowed: GeneratedReceipts::Validator::REFERENCE_CANDIDATE_REJECTION_REASONS,
            maximum: GeneratedReceipts::Validator::MAX_REJECTION_REASONS
          )
          if candidate["validation_state"] == "valid"
            if Array(candidate["rejection_reasons"]).any?
              add_error("#{path}.rejection_reasons", "must be empty for valid")
            end
          elsif candidate["rejection_reasons"].is_a?(Array) && candidate["rejection_reasons"].empty?
            add_error("#{path}.rejection_reasons", "must explain a non-valid candidate")
          end
          validate_optional_decimal(
            "#{path}.reference_price_amount",
            candidate["reference_price_amount"],
            maximum: MAX_PRICE
          )
          %w[reference_quantity purchased_quantity].each do |field|
            validate_optional_decimal(
              "#{path}.#{field}",
              candidate[field],
              maximum: MAX_QUANTITY
            )
          end
          %w[reference_unit_code purchased_unit_code].each do |field|
            validate_optional_token("#{path}.#{field}", candidate[field])
          end
          validate_optional_inclusion(
            "#{path}.reference_price_tax_inclusion",
            candidate["reference_price_tax_inclusion"],
            TAX_INCLUSIONS
          )
          validate_optional_line_total("#{path}.projected_line_total", candidate["projected_line_total"])
          validate_optional_line_total("#{path}.printed_line_total", candidate["printed_line_total"])
          validate_token_array(
            "#{path}.rounding_matches",
            candidate["rounding_matches"],
            allowed: GeneratedReceipts::Validator::ROUNDING_MATCHES,
            maximum: GeneratedReceipts::Validator::MAX_ROUNDING_MATCHES
          )
        end
      end

      def validate_associations(value)
        validate_array("ground_truth.expected_associations", value) do |association, index|
          path = "ground_truth.expected_associations[#{index}]"
          validate_hash(path, association, required: ASSOCIATION_KEYS, allowed: ASSOCIATION_KEYS)
          next unless association.is_a?(Hash)

          validate_index("#{path}.candidate_index", association["candidate_index"])
          validate_item_index("#{path}.item_index", association["item_index"])
          validate_inclusion("#{path}.evidence_scope", association["evidence_scope"], EVIDENCE_SCOPES)
        end
      end

      def validate_contract
        ground_truth = case_data.fetch("ground_truth")
        items = ground_truth.fetch("items")
        candidates = ground_truth.fetch("expected_candidates")
        associations = ground_truth.fetch("expected_associations")

        validate_unique_indexes("ground_truth.items", items, "item_index")
        validate_unique_indexes("ground_truth.expected_associations", associations, "candidate_index")
        validate_association_coverage(candidates, associations, items)

        items.each_with_index do |item, index|
          item_candidates = candidates.select { |candidate| candidate["item_index"] == item["item_index"] }
          if item["evidence_class"] != "reference_pricing" && item_candidates.any?
            add_error(
              "ground_truth.expected_candidates",
              "must not contain candidates for non-reference item #{item['item_index']}"
            )
          end
          validate_candidate_printed_totals(item, item_candidates)
          projection_facts = validate_projection_contract(item, item_candidates, index)
          association_evidence_complete = same_item_association_complete?(
            item: item,
            candidates: candidates,
            associations: associations
          )

          blockers = derived_blockers(
            item,
            item_candidates,
            projection_facts,
            association_evidence_complete:
          )
          unless item["adoption_blocking_reasons"] == blockers
            add_error(
              "ground_truth.items[#{index}].adoption_blocking_reasons",
              "must equal derived blockers #{blockers.inspect}"
            )
          end

          outcome = derived_outcome(item, item_candidates, blockers, projection_facts)
          unless item["adoption_outcome"] == outcome
            add_error(
              "ground_truth.items[#{index}].adoption_outcome",
              "must equal derived outcome #{outcome}"
            )
          end
        end
      end

      def same_item_association_complete?(item:, candidates:, associations:)
        candidate_indexes = candidates.each_index.select do |candidate_index|
          candidates[candidate_index]["item_index"] == item["item_index"]
        end
        return item["same_item_evidence"] if candidate_indexes.empty?

        candidate_indexes.all? do |candidate_index|
          associations.any? do |association|
            association["candidate_index"] == candidate_index &&
              association["item_index"] == item["item_index"] &&
              association["evidence_scope"] == "same_item"
          end
        end
      end

      def validate_association_coverage(candidates, associations, items)
        candidate_indexes = (0...candidates.size).to_a
        association_indexes = associations.map { |association| association["candidate_index"] }.sort
        unless association_indexes == candidate_indexes
          add_error(
            "ground_truth.expected_associations",
            "candidate indexes must exactly cover expected_candidates"
          )
        end

        item_indexes = items.map { |item| item["item_index"] }
        associations.each_with_index do |association, index|
          candidate = candidates[association["candidate_index"]]
          unless item_indexes.include?(association["item_index"])
            add_error("ground_truth.expected_associations[#{index}].item_index", "must identify a ground-truth item")
          end
          next unless candidate
          next if candidate["item_index"] == association["item_index"]

          add_error(
            "ground_truth.expected_associations[#{index}].item_index",
            "must match the candidate item_index"
          )
        end
      end

      def validate_candidate_printed_totals(item, candidates)
        candidates.each_with_index do |candidate, index|
          next if candidate["printed_line_total"] == item["printed_line_total"]

          candidate_index = case_data.dig("ground_truth", "expected_candidates").index(candidate) || index
          add_error(
            "ground_truth.expected_candidates[#{candidate_index}].printed_line_total",
            "must match the ground-truth item"
          )
        end
      end

      def derived_blockers(item, candidates, projection_facts, association_evidence_complete:)
        blockers = []
        blockers << "printed_total_present" unless item["printed_line_total"].nil?
        blockers << "existing_authority_present" if item["existing_authority"]

        sole_candidate = candidates.one? ? candidates.first : nil
        if sole_candidate.nil?
          blockers << "candidate_count_not_one"
        else
          blockers << "candidate_not_valid" unless sole_candidate["validation_state"] == "valid"
          unless %w[reference_price_amount reference_quantity reference_unit_code].all? do |field|
            component_present?(sole_candidate[field])
          end
            blockers << "reference_components_incomplete"
          end
          unless %w[purchased_quantity purchased_unit_code].all? do |field|
            component_present?(sole_candidate[field])
          end
            blockers << "purchased_components_incomplete"
          end
          blockers << "dimension_incompatible" unless projection_facts[:dimension_compatible]
        end

        unless item["same_item_evidence"] && association_evidence_complete
          blockers << "same_item_evidence_incomplete"
        end
        if sole_candidate && !%w[gross net].include?(sole_candidate["reference_price_tax_inclusion"])
          blockers << "item_local_tax_basis_missing"
        end
        if sole_candidate&.dig("reference_price_tax_inclusion") == "net" &&
            (!valid_tax_rate?(item["item_local_tax_rate"]) || item["tax_rate_conflict"])
          blockers << "item_local_tax_rate_missing_or_conflicting"
        end
        blockers << "package_conflict" if item["package_conflict"]
        blockers << "discount_conflict" if item["discount_conflict"]
        if sole_candidate
          blockers << "deterministic_projection_unavailable" unless projection_facts[:deterministic]
          blockers << "projected_amount_out_of_bounds" unless projection_facts[:within_bounds]
        end
        blockers
      end

      def validate_projection_contract(item, candidates, item_position)
        facts = projection_facts(item, candidates.one? ? candidates.first : nil)
        {
          "dimension_compatible" => facts[:dimension_compatible],
          "deterministic_projection" => facts[:deterministic],
          "projection_within_bounds" => facts[:within_bounds],
          "projected_gross_line_total" => facts[:projected_gross_line_total]
        }.each do |field, expected_value|
          next if item[field] == expected_value

          add_error(
            "ground_truth.items[#{item_position}].#{field}",
            "must equal independently derived #{expected_value.inspect}"
          )
        end

        return facts unless candidates.one?

        candidate = candidates.first
        candidate_index = case_data.dig("ground_truth", "expected_candidates").index(candidate)
        return facts if candidate["projected_line_total"] == facts[:projected_line_total]

        add_error(
          "ground_truth.expected_candidates[#{candidate_index}].projected_line_total",
          "must equal independently derived #{facts[:projected_line_total].inspect}"
        )
        facts
      end

      def projection_facts(item, candidate)
        empty = {
          dimension_compatible: true,
          deterministic: false,
          within_bounds: true,
          projected_line_total: nil,
          projected_gross_line_total: nil
        }
        return empty unless candidate

        price = bounded_exact_decimal(
          candidate["reference_price_amount"],
          maximum: MeasurementContract::MAX_PRICE_AMOUNT,
          max_scale: 6,
          allow_zero: true
        )
        reference_quantity = bounded_exact_decimal(
          candidate["reference_quantity"],
          maximum: MeasurementContract::MAX_QUANTITY,
          max_scale: 3
        )
        purchased_quantity = bounded_exact_decimal(
          candidate["purchased_quantity"],
          maximum: MeasurementContract::MAX_QUANTITY,
          max_scale: 3
        )
        dimension_compatible, ratio = unit_relationship(
          from: candidate["purchased_unit_code"],
          to: candidate["reference_unit_code"]
        )
        return empty.merge(dimension_compatible: dimension_compatible) unless price && reference_quantity && purchased_quantity && ratio

        exact_amount = price * purchased_quantity * ratio / reference_quantity
        projected_line_total = round_rational(exact_amount, "round")
        tax_inclusion = candidate["reference_price_tax_inclusion"]
        projected_gross = case tax_inclusion
        when "gross"
          projected_line_total
        when "net"
          rate = bounded_exact_decimal(
            item["item_local_tax_rate"],
            maximum: MeasurementContract::MAX_RATE,
            max_scale: 6,
            allow_zero: true
          )
          if rate && !item["tax_rate_conflict"]
            projected_line_total + round_rational(
              projected_line_total * rate,
              item["tax_rounding_mode"]
            )
          end
        end
        deterministic = !projected_gross.nil?
        source_within_bounds = projected_line_total.between?(0, MeasurementContract::MAX_LINE_TOTAL)
        gross_within_bounds = projected_gross.nil? ||
          projected_gross.between?(0, MeasurementContract::MAX_LINE_TOTAL)
        within_bounds = source_within_bounds && gross_within_bounds

        if within_bounds
          contract_projection = MeasurementContract.project(
            source_item: {
              "reference_price_amount" => candidate["reference_price_amount"],
              "reference_quantity" => candidate["reference_quantity"],
              "reference_unit" => candidate["reference_unit_code"],
              "purchased_quantity" => candidate["purchased_quantity"],
              "purchased_unit" => candidate["purchased_unit_code"],
              "reference_price_tax_inclusion" => tax_inclusion
            },
            tax_rate: item["item_local_tax_rate"],
            tax_rounding: item["tax_rounding_mode"],
            discount_rounding: "round"
          )
          unless contract_projection &&
              contract_projection.projected_reference_line_total == projected_line_total &&
              contract_projection.projected_gross_line_total == projected_gross
            return empty.merge(dimension_compatible: dimension_compatible)
          end
        end

        {
          dimension_compatible: dimension_compatible,
          deterministic: deterministic,
          within_bounds: within_bounds,
          projected_line_total: source_within_bounds ? projected_line_total : nil,
          projected_gross_line_total: within_bounds ? projected_gross : nil
        }
      rescue ArgumentError, TypeError, ZeroDivisionError, FloatDomainError, RangeError
        empty
      end

      def bounded_exact_decimal(value, maximum:, max_scale:, allow_zero: false)
        return unless value.is_a?(String) && value.bytesize.between?(1, MAX_TOKEN_BYTES)
        return unless value.valid_encoding? && value.ascii_only? && value.match?(DECIMAL_PATTERN)
        return if value.include?(".") && value.split(".", 2).last.length > max_scale

        exact = Rational(value)
        return if exact.negative? || (exact.zero? && !allow_zero) || exact > maximum

        exact
      rescue ArgumentError, TypeError, ZeroDivisionError, EncodingError
        nil
      end

      def unit_relationship(from:, to:)
        from_dimension, from_scale = MeasurementContract::UNIT_SCALES[from]
        to_dimension, to_scale = MeasurementContract::UNIT_SCALES[to]
        return [ true, nil ] unless from_dimension && to_dimension
        return [ false, nil ] unless from_dimension == to_dimension

        [ true, from_scale / to_scale ]
      end

      def round_rational(value, mode)
        case mode
        when "ceil"
          value.ceil
        when "round"
          (value + Rational(1, 2)).floor
        else
          value.floor
        end
      end

      def derived_outcome(item, candidates, blockers, projection_facts)
        return "eligible" if blockers.empty?

        sole_candidate = candidates.one? ? candidates.first : nil
        return "unsupported" if item["evidence_class"] != "reference_pricing"
        return "unsupported" if sole_candidate&.dig("validation_state") == "unsupported"
        if sole_candidate
          return "unsupported" unless projection_facts[:dimension_compatible]
          return "unsupported" unless projection_facts[:within_bounds]
        end

        "review"
      end

      def component_present?(value)
        !value.nil? && (!value.is_a?(String) || !value.empty?)
      end

      def valid_tax_rate?(value)
        decimal = exact_decimal(value)
        !decimal.nil? && decimal >= 0 && decimal <= 1
      end

      def validate_unique_indexes(path, entries, key)
        indexes = entries.map { |entry| entry[key] }
        add_error(path, "must have unique #{key} values") unless indexes.uniq.size == indexes.size
      end

      def validate_hash(path, value, required:, allowed:)
        unless value.is_a?(Hash)
          add_error(path, "must be an object")
          return
        end

        required.each do |key|
          add_error("#{path}.#{key}", "is required") unless value.key?(key)
        end
        add_error("#{path}.invalid_key", "is not allowed") if (value.keys - allowed).any?
      end

      def validate_array(path, value, minimum: 0, maximum: MAX_COLLECTION_ITEMS)
        unless value.is_a?(Array)
          add_error(path, "must be an array")
          return
        end
        add_error(path, "must contain at least #{minimum} item(s)") if value.size < minimum
        add_error(path, "must contain at most #{maximum} item(s)") if value.size > maximum
        value.first(maximum).each_with_index { |entry, index| yield(entry, index) if block_given? }
      end

      def validate_text_array(path, value, minimum: 0)
        validate_array(path, value, minimum: minimum, maximum: MAX_SOURCE_LINES) do |entry, index|
          validate_text("#{path}[#{index}]", entry, allow_line_breaks: false)
        end
      end

      def validate_token_array(path, value, allowed:, maximum: MAX_COLLECTION_ITEMS)
        validate_array(path, value, maximum: maximum) do |entry, index|
          validate_inclusion("#{path}[#{index}]", entry, allowed)
        end
        if value.is_a?(Array) && value.uniq.size != value.size
          add_error(path, "must contain unique values")
        end
      end

      def validate_text(path, value, allow_line_breaks: false)
        unless value.is_a?(String) && !value.empty? && value.bytesize <= MAX_TEXT_BYTES && value.valid_encoding?
          add_error(path, "must be a bounded non-empty string")
          return
        end
        pattern = allow_line_breaks ? /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/ : CONTROL_PATTERN
        add_error(path, "contains unsupported control characters") if value.match?(pattern)
      rescue EncodingError
        add_error(path, "must be a bounded non-empty string")
      end

      def validate_optional_text(path, value)
        validate_text(path, value) unless value.nil?
      end

      def validate_boolean(path, value)
        add_error(path, "must be a boolean") unless value == true || value == false
      end

      def validate_inclusion(path, value, allowed)
        add_error(path, "is not an allowed value") unless allowed.include?(value)
      end

      def validate_optional_inclusion(path, value, allowed)
        validate_inclusion(path, value, allowed) unless value.nil?
      end

      def validate_index(path, value)
        unless value.is_a?(Integer) && value.between?(0, MAX_COLLECTION_ITEMS - 1)
          add_error(path, "must be an integer between 0 and #{MAX_COLLECTION_ITEMS - 1}")
        end
      end

      alias_method :validate_item_index, :validate_index

      def validate_optional_token(path, value)
        return if value.nil?
        unless value.is_a?(String) && value.bytesize.between?(1, MAX_TOKEN_BYTES) &&
            value.valid_encoding? && !value.match?(CONTROL_PATTERN)
          add_error(path, "must be a bounded token or null")
        end
      rescue EncodingError
        add_error(path, "must be a bounded token or null")
      end

      def validate_optional_decimal(path, value, maximum:)
        return if value.nil?
        decimal = exact_decimal(value)
        unless decimal && decimal >= 0 && decimal <= maximum
          add_error(path, "must be a bounded plain decimal string or null")
        end
      end

      def validate_optional_tax_rate(path, value)
        return if value.nil?
        add_error(path, "must be an exact decimal between 0 and 1 or null") unless valid_tax_rate?(value)
      end

      def exact_decimal(value)
        return unless value.is_a?(String) && value.bytesize.between?(1, MAX_TOKEN_BYTES)
        return unless value.valid_encoding? && value.ascii_only? && value.match?(DECIMAL_PATTERN)

        BigDecimal(value)
      rescue ArgumentError, TypeError, FloatDomainError, EncodingError
        nil
      end

      def validate_optional_line_total(path, value)
        return if value.nil?
        unless value.is_a?(Integer) && value.between?(0, MAX_LINE_TOTAL)
          add_error(path, "must be a bounded non-negative integer or null")
        end
      end

      def add_error(path, message)
        return if errors.size >= MAX_ERRORS

        errors << "#{path}: #{message}"
      end

      def safe_case_id
        value = case_data["case_id"] if case_data.is_a?(Hash)
        value if self.class.valid_case_id?(value)
      end
    end
  end
end
