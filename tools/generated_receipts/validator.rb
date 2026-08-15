# frozen_string_literal: true

require "bigdecimal"
require "json"

module GeneratedReceipts
  class Validator
    class FixtureLoadError < StandardError; end

    Result = Struct.new(:case_id, :errors, keyword_init: true) do
      def valid?
        errors.empty?
      end
    end

    TOP_LEVEL_KEYS = %w[
      case_id
      category
      intent
      receipt_kind
      expected
      render
      degradation
      assertions
      source
    ].freeze
    TOP_LEVEL_REQUIRED_KEYS = (TOP_LEVEL_KEYS - %w[source]).freeze
    EXPECTED_KEYS = %w[
      store_name
      store_address
      purchased_at
      currency
      amount_basis
      tax_rate
      rounding
      items
      receipt_adjustments
      tax_details
      subtotal
      tax
      total
      payments
      payment_sum
      payment_method
      settlement
      status
      review_reasons
      processing_error_code
      measurement_projections
      reference_pricing_candidates
    ].freeze
    EXPECTED_REQUIRED_KEYS = (
      EXPECTED_KEYS - %w[
        settlement
        processing_error_code
        measurement_projections
        reference_pricing_candidates
      ]
    ).freeze
    NON_RECEIPT_EXPECTED_REQUIRED_KEYS = %w[
      status
      review_reasons
      processing_error_code
    ].freeze
    ROUNDING_KEYS = %w[tax discount scope].freeze
    ITEM_KEYS = %w[
      name
      unit_price
      quantity
      line_total
      tax_rate
      discount_amount
      tax_inclusion
      quantity_unit_code
      pricing_source_kind
      reference_price_amount
      reference_quantity
      reference_quantity_unit_code
      reference_price_tax_inclusion
      original_line_total
    ].freeze
    ITEM_REQUIRED_KEYS = %w[
      name
      unit_price
      quantity
      line_total
      tax_rate
      discount_amount
    ].freeze
    ADJUSTMENT_KEYS = %w[
      kind
      label
      sign
      amount
      effect
      tax_rate
      tax_inclusion
      review_reasons
    ].freeze
    ADJUSTMENT_REQUIRED_KEYS = %w[
      kind
      label
      sign
      amount
      effect
    ].freeze
    TAX_DETAIL_KEYS = %w[rate net tax gross basis label].freeze
    TAX_DETAIL_REQUIRED_KEYS = %w[rate net tax gross basis].freeze
    PAYMENT_KEYS = %w[method label amount].freeze
    PAYMENT_REQUIRED_KEYS = PAYMENT_KEYS.freeze
    SETTLEMENT_KEYS = %w[tendered change payment_label].freeze
    RENDER_KEYS = %w[
      locale
      paper_width
      font
      include_tax_detail_lines
      omit_subtotal_line
      include_payment_heading
      noise_lines
      custom_lines
    ].freeze
    DEGRADATION_KEYS = %w[enabled profile].freeze
    ASSERTION_KEYS = %w[
      critical_exact
      allow_review_reasons
      allow_item_name_minor_diff
      simulated_ai_item_tax_rate
      expected_item_tax_rate_after_save
    ].freeze
    SOURCE_KEYS = %w[context items].freeze
    SOURCE_ITEM_KEYS = %w[
      item_index
      printed_lines
      purchased_quantity
      purchased_unit
      reference_price_amount
      reference_quantity
      reference_unit
      reference_price_tax_inclusion
      printed_line_total
      discount_rate
      discount_amount
    ].freeze
    SOURCE_ITEM_REQUIRED_KEYS = %w[item_index printed_lines purchased_quantity purchased_unit].freeze
    MEASUREMENT_PROJECTION_KEYS = %w[
      item_index
      exact_reference_amount
      projected_reference_line_total
      discount_amount
      discounted_source_line_total
      projected_gross_line_total
    ].freeze
    MEASUREMENT_PROJECTION_REQUIRED_KEYS = MEASUREMENT_PROJECTION_KEYS.freeze
    EXACT_AMOUNT_KEYS = %w[numerator denominator].freeze
    REFERENCE_CANDIDATE_KEYS = %w[
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
    REFERENCE_CANDIDATE_REQUIRED_KEYS = %w[item_index validation_state rejection_reasons].freeze
    CATEGORIES = %w[normal payment discount_adjustment tax_rounding ocr_anomaly non_receipt conflict measurement].freeze
    RECEIPT_KINDS = %w[receipt non_receipt].freeze
    SOURCE_CONTEXTS = %w[analysis manual edit_save].freeze
    REFERENCE_CANDIDATE_STATES = %w[valid missing ambiguous unsupported none].freeze
    REFERENCE_CANDIDATE_REJECTION_REASONS = %w[
      missing_reference_price
      missing_reference_quantity
      missing_reference_unit
      missing_purchased_quantity
      missing_purchased_unit
      ambiguous_reference_expression
      ambiguous_purchased_quantity
      ambiguous_tax_inclusion
      unsupported_reference_unit
      unsupported_purchased_unit
      incompatible_unit_dimension
      invalid_reference_price
      invalid_reference_quantity
      invalid_purchased_quantity
      reference_price_out_of_bounds
      reference_quantity_out_of_bounds
      purchased_quantity_out_of_bounds
      evidence_outside_item
      insufficient_component_evidence
    ].freeze
    PRICING_SOURCE_KINDS = %w[count_unit_price reference_quantity_price explicit_line_total].freeze
    AMOUNT_BASES = %w[tax_included tax_excluded mixed].freeze
    TAX_INCLUSIONS = %w[gross net].freeze
    ADJUSTMENT_EFFECTS = %w[purchase payment].freeze
    ADJUSTMENT_SIGNS = %w[surcharge discount].freeze
    ROUNDING_MODES = %w[floor round ceil].freeze
    ROUNDING_MATCHES = %w[floor half_up ceil].freeze
    MAX_ITEM_COUNT = 100
    MAX_ITEM_INDEX = MAX_ITEM_COUNT - 1
    MAX_COLLECTION_ITEMS = 100
    MAX_PRINTED_LINES = 100
    MAX_REJECTION_REASONS = 8
    MAX_ROUNDING_MATCHES = ROUNDING_MATCHES.size
    MAX_SOURCE_LINE_BYTES = 512
    MAX_SOURCE_ITEM_BYTES = 4_096
    MAX_EXACT_TOKEN_BYTES = 64
    MAX_OBJECT_KEYS = 100
    MAX_ERRORS = 1_000
    MAX_CASE_FILE_BYTES = 4 * 1024 * 1024
    MAX_JSON_NESTING = 16
    MAX_CASE_ID_BYTES = 64
    MAX_ARTIFACT_EXTENSION_BYTES = 16
    MAX_FIXTURE_TEXT_BYTES = 512
    MAX_NUMERIC_BITS = 128
    FIXTURE_LOAD_ERROR_MESSAGE = "generated receipt fixture could not be loaded safely"
    CASE_ID_PATTERN = /\Ag\d{3}_[a-z0-9_]+\z/.freeze
    ARTIFACT_EXTENSION_PATTERN = /\A[a-z0-9]+\z/.freeze
    EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
    EXACT_INTEGER_PATTERN = /\A(?:0|[1-9]\d*)\z/.freeze
    CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F-\u009F]/.freeze
    FIXTURE_TEXT_CONTROL_PATTERN = /[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]/.freeze

    class << self
      def call(value)
        new(value).call
      end

      def load_file(path)
        fixture_path = safe_fixture_path(path)
        payload = read_bounded_fixture(fixture_path)
        value = JSON.parse(payload, max_nesting: MAX_JSON_NESTING)
        validate_loaded_case_identity!(value, fixture_path)
        value
      rescue FixtureLoadError
        raise
      rescue JSON::ParserError, EncodingError, SystemCallError, ArgumentError, TypeError
        raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
      end

      def valid_case_id?(value)
        value.is_a?(String) && value.bytesize.between?(1, MAX_CASE_ID_BYTES) &&
          value.valid_encoding? && value.ascii_only? &&
          value.match?(CASE_ID_PATTERN)
      rescue EncodingError
        false
      end

      def artifact_path(root:, case_id:, extension:, must_exist: false)
        raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE unless valid_case_id?(case_id)
        unless extension.is_a?(String) &&
            extension.bytesize.between?(1, MAX_ARTIFACT_EXTENSION_BYTES) &&
            extension.valid_encoding? && extension.ascii_only? &&
            extension.match?(ARTIFACT_EXTENSION_PATTERN)
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end

        root_path = File.expand_path(File.path(root))
        root_real_path = File.realpath(root_path)
        candidate = File.expand_path("#{case_id}.#{extension}", root_path)
        unless path_within_root?(candidate, root_path)
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end

        exists = File.exist?(candidate) || File.symlink?(candidate)
        if exists
          unless File.lstat(candidate).file?
            raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
          end
          unless path_within_root?(File.realpath(candidate), root_real_path)
            raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
          end
        elsif must_exist
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end

        candidate
      rescue FixtureLoadError
        raise
      rescue EncodingError, SystemCallError, ArgumentError, TypeError
        raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
      end

      private

      def safe_fixture_path(path)
        candidate = File.expand_path(File.path(path))
        unless File.extname(candidate) == ".json" && File.lstat(candidate).file?
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end

        resolved = File.realpath(candidate)
        approved = [ GeneratedReceipts::CASES_DIR, GeneratedReceipts::MEASUREMENT_CASES_DIR ].any? do |root|
          path_within_root?(resolved, File.realpath(root))
        end
        raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE unless approved

        resolved
      end

      def read_bounded_fixture(path)
        payload = File.open(path, "rb") { |file| file.read(MAX_CASE_FILE_BYTES + 1) }
        if payload.nil? || payload.bytesize > MAX_CASE_FILE_BYTES
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end

        payload.force_encoding(Encoding::UTF_8)
        raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE unless payload.valid_encoding?

        payload
      end

      def validate_loaded_case_identity!(value, path)
        unless value.is_a?(Hash) && valid_case_id?(value["case_id"]) &&
            value["case_id"] == File.basename(path, ".json")
          raise FixtureLoadError, FIXTURE_LOAD_ERROR_MESSAGE
        end
      end

      def path_within_root?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end
    end

    def initialize(value)
      @case_data = value
      @errors = []
    end

    def call
      validate_schema
      validate_amounts if errors.empty? && receipt_case?

      case_id = case_data["case_id"] if case_data.is_a?(Hash)
      Result.new(case_id: case_id, errors: errors)
    end

    private

    attr_reader :case_data, :errors

    def validate_schema
      validate_hash("case", case_data, required: TOP_LEVEL_REQUIRED_KEYS, allowed: TOP_LEVEL_KEYS)
      return unless case_data.is_a?(Hash)

      validate_case_id
      validate_inclusion("category", case_data["category"], CATEGORIES)
      validate_inclusion("receipt_kind", case_data["receipt_kind"], RECEIPT_KINDS)
      validate_bounded_text("intent", case_data["intent"])
      validate_hash("expected", expected, required: expected_required_keys, allowed: EXPECTED_KEYS)
      validate_hash("render", case_data["render"], required: [], allowed: RENDER_KEYS)
      validate_hash("degradation", case_data["degradation"], required: DEGRADATION_KEYS, allowed: DEGRADATION_KEYS)
      validate_hash("assertions", case_data["assertions"], required: [], allowed: ASSERTION_KEYS)
      validate_render_values
      validate_assertion_values
      validate_source
      validate_degradation
      validate_non_receipt_schema unless receipt_case?
      return unless receipt_case?
      return unless expected.is_a?(Hash)

      validate_receipt_expected_values
      rounding = expected["rounding"]
      validate_hash("expected.rounding", rounding, required: ROUNDING_KEYS, allowed: ROUNDING_KEYS)
      validate_optional_hash("expected.settlement", expected["settlement"], allowed: SETTLEMENT_KEYS)
      validate_inclusion("expected.amount_basis", expected["amount_basis"], AMOUNT_BASES)
      if rounding.is_a?(Hash)
        validate_inclusion("expected.rounding.tax", rounding["tax"], ROUNDING_MODES)
        validate_inclusion("expected.rounding.discount", rounding["discount"], ROUNDING_MODES)
        validate_bounded_text("expected.rounding.scope", rounding["scope"])
      end
      validate_array("expected.items", expected["items"]) do |item, index|
        validate_hash("expected.items[#{index}]", item, required: ITEM_REQUIRED_KEYS, allowed: ITEM_KEYS)
        next unless item.is_a?(Hash)

        validate_optional_inclusion("expected.items[#{index}].tax_inclusion", item["tax_inclusion"], TAX_INCLUSIONS)
        validate_optional_inclusion(
          "expected.items[#{index}].pricing_source_kind",
          item["pricing_source_kind"],
          PRICING_SOURCE_KINDS
        )
        validate_optional_inclusion(
          "expected.items[#{index}].reference_price_tax_inclusion",
          item["reference_price_tax_inclusion"],
          TAX_INCLUSIONS
        )
        validate_mixed_tax_inclusion("expected.items[#{index}].tax_inclusion", item["tax_inclusion"])
        validate_bounded_text("expected.items[#{index}].name", item["name"], allow_line_breaks: true)
        validate_optional_number("expected.items[#{index}].unit_price", item["unit_price"])
        validate_bounded_decimal_token(
          "expected.items[#{index}].quantity",
          item["quantity"],
          allow_numeric: true
        )
        validate_optional_integer("expected.items[#{index}].line_total", item["line_total"])
        validate_optional_number("expected.items[#{index}].tax_rate", item["tax_rate"])
        validate_optional_integer("expected.items[#{index}].discount_amount", item["discount_amount"])
        validate_bounded_token("expected.items[#{index}].quantity_unit_code", item["quantity_unit_code"])
        validate_bounded_token(
          "expected.items[#{index}].reference_quantity_unit_code",
          item["reference_quantity_unit_code"]
        )
        validate_optional_integer(
          "expected.items[#{index}].original_line_total",
          item["original_line_total"],
          maximum: MeasurementContract::MAX_LINE_TOTAL
        )
        validate_bounded_decimal_token(
          "expected.items[#{index}].reference_price_amount",
          item["reference_price_amount"],
          allow_numeric: true
        )
        validate_bounded_decimal_token(
          "expected.items[#{index}].reference_quantity",
          item["reference_quantity"],
          allow_numeric: true
        )
      end
      validate_measurement_projections
      validate_reference_pricing_candidates
      validate_array("expected.receipt_adjustments", expected["receipt_adjustments"]) do |adjustment, index|
        validate_hash("expected.receipt_adjustments[#{index}]", adjustment, required: ADJUSTMENT_REQUIRED_KEYS, allowed: ADJUSTMENT_KEYS)
        next unless adjustment.is_a?(Hash)

        validate_inclusion("expected.receipt_adjustments[#{index}].effect", adjustment["effect"], ADJUSTMENT_EFFECTS)
        validate_inclusion("expected.receipt_adjustments[#{index}].sign", adjustment["sign"], ADJUSTMENT_SIGNS)
        validate_bounded_text("expected.receipt_adjustments[#{index}].kind", adjustment["kind"])
        validate_bounded_text("expected.receipt_adjustments[#{index}].label", adjustment["label"], allow_line_breaks: true)
        validate_integer("expected.receipt_adjustments[#{index}].amount", adjustment["amount"])
        validate_optional_number("expected.receipt_adjustments[#{index}].tax_rate", adjustment["tax_rate"])
        if adjustment.key?("review_reasons")
          validate_bounded_text_array(
            "expected.receipt_adjustments[#{index}].review_reasons",
            adjustment["review_reasons"]
          )
        end
        validate_optional_inclusion("expected.receipt_adjustments[#{index}].tax_inclusion", adjustment["tax_inclusion"], TAX_INCLUSIONS)
        validate_mixed_tax_inclusion("expected.receipt_adjustments[#{index}].tax_inclusion", adjustment["tax_inclusion"]) if adjustment["effect"] == "purchase"
      end
      validate_array("expected.tax_details", expected["tax_details"]) do |tax_detail, index|
        validate_hash("expected.tax_details[#{index}]", tax_detail, required: TAX_DETAIL_REQUIRED_KEYS, allowed: TAX_DETAIL_KEYS)
        next unless tax_detail.is_a?(Hash)

        validate_inclusion("expected.tax_details[#{index}].basis", tax_detail["basis"], TAX_INCLUSIONS)
        validate_number("expected.tax_details[#{index}].rate", tax_detail["rate"])
        %w[net tax gross].each do |field|
          validate_integer("expected.tax_details[#{index}].#{field}", tax_detail[field])
        end
        validate_optional_bounded_text(
          "expected.tax_details[#{index}].label",
          tax_detail["label"],
          allow_line_breaks: true
        )
      end
      validate_array("expected.payments", expected["payments"]) do |payment, index|
        validate_hash("expected.payments[#{index}]", payment, required: PAYMENT_REQUIRED_KEYS, allowed: PAYMENT_KEYS)
        next unless payment.is_a?(Hash)

        validate_bounded_text("expected.payments[#{index}].method", payment["method"])
        validate_bounded_text("expected.payments[#{index}].label", payment["label"], allow_line_breaks: true)
        validate_integer("expected.payments[#{index}].amount", payment["amount"])
      end
    end

    def validate_source
      source = case_data["source"]
      if source.nil?
        add_error("source", "is required for Measurement cases") if case_data["category"] == "measurement"
        return
      end

      validate_hash("source", source, required: SOURCE_KEYS, allowed: SOURCE_KEYS)
      return unless source.is_a?(Hash)

      validate_inclusion("source.context", source["context"], SOURCE_CONTEXTS)
      validate_array("source.items", source["items"]) do |item, index|
        validate_hash(
          "source.items[#{index}]",
          item,
          required: SOURCE_ITEM_REQUIRED_KEYS,
          allowed: SOURCE_ITEM_KEYS
        )
        next unless item.is_a?(Hash)

        validate_item_index("source.items[#{index}].item_index", item["item_index"])
        validate_array(
          "source.items[#{index}].printed_lines",
          item["printed_lines"],
          maximum: MAX_PRINTED_LINES
        )
        printed_lines = item["printed_lines"]
        validate_printed_lines("source.items[#{index}].printed_lines", printed_lines)
        validate_bounded_decimal_token(
          "source.items[#{index}].purchased_quantity",
          item["purchased_quantity"]
        )
        validate_bounded_token("source.items[#{index}].purchased_unit", item["purchased_unit"])
        validate_bounded_decimal_token(
          "source.items[#{index}].reference_price_amount",
          item["reference_price_amount"]
        )
        validate_bounded_decimal_token(
          "source.items[#{index}].reference_quantity",
          item["reference_quantity"]
        )
        validate_bounded_token("source.items[#{index}].reference_unit", item["reference_unit"])
        validate_bounded_decimal_token(
          "source.items[#{index}].discount_rate",
          item["discount_rate"]
        )
        validate_bounded_non_negative_integer(
          "source.items[#{index}].printed_line_total",
          item["printed_line_total"],
          maximum: MeasurementContract::MAX_LINE_TOTAL
        )
        validate_bounded_non_negative_integer(
          "source.items[#{index}].discount_amount",
          item["discount_amount"],
          maximum: MeasurementContract::MAX_LINE_TOTAL
        )
        validate_optional_inclusion(
          "source.items[#{index}].reference_price_tax_inclusion",
          item["reference_price_tax_inclusion"],
          TAX_INCLUSIONS + [ "unknown" ]
        )
      end
      add_error("category", "must be measurement when source is present") unless case_data["category"] == "measurement"
    end

    def validate_measurement_projections
      value = expected["measurement_projections"]
      return if value.nil? && case_data["source"].nil?

      validate_array("expected.measurement_projections", value) do |projection, index|
        validate_hash(
          "expected.measurement_projections[#{index}]",
          projection,
          required: MEASUREMENT_PROJECTION_REQUIRED_KEYS,
          allowed: MEASUREMENT_PROJECTION_KEYS
        )
        next unless projection.is_a?(Hash)

        validate_item_index(
          "expected.measurement_projections[#{index}].item_index",
          projection["item_index"]
        )
        exact_amount = projection["exact_reference_amount"]
        validate_optional_hash(
          "expected.measurement_projections[#{index}].exact_reference_amount",
          exact_amount,
          allowed: EXACT_AMOUNT_KEYS
        )
        (MEASUREMENT_PROJECTION_KEYS - %w[item_index exact_reference_amount]).each do |key|
          validate_bounded_non_negative_integer(
            "expected.measurement_projections[#{index}].#{key}",
            projection[key],
            maximum: MeasurementContract::MAX_LINE_TOTAL
          )
        end
        next if exact_amount.nil? || !exact_amount.is_a?(Hash)

        missing = EXACT_AMOUNT_KEYS - exact_amount.keys
        missing.each do |key|
          add_error("expected.measurement_projections[#{index}].exact_reference_amount.#{key}", "is required")
        end
        EXACT_AMOUNT_KEYS.each do |key|
          validate_bounded_integer_token(
            "expected.measurement_projections[#{index}].exact_reference_amount.#{key}",
            exact_amount[key]
          )
        end
        if exact_amount["denominator"] == "0"
          add_error(
            "expected.measurement_projections[#{index}].exact_reference_amount.denominator",
            "must be positive"
          )
        end
      end
    end

    def validate_reference_pricing_candidates
      value = expected["reference_pricing_candidates"]
      return if value.nil? && case_data["source"].nil?

      validate_array("expected.reference_pricing_candidates", value) do |candidate, index|
        validate_hash(
          "expected.reference_pricing_candidates[#{index}]",
          candidate,
          required: REFERENCE_CANDIDATE_REQUIRED_KEYS,
          allowed: REFERENCE_CANDIDATE_KEYS
        )
        next unless candidate.is_a?(Hash)

        validate_item_index(
          "expected.reference_pricing_candidates[#{index}].item_index",
          candidate["item_index"]
        )
        validate_inclusion(
          "expected.reference_pricing_candidates[#{index}].validation_state",
          candidate["validation_state"],
          REFERENCE_CANDIDATE_STATES
        )
        validate_array(
          "expected.reference_pricing_candidates[#{index}].rejection_reasons",
          candidate["rejection_reasons"],
          maximum: MAX_REJECTION_REASONS
        ) do |reason, reason_index|
          validate_inclusion(
            "expected.reference_pricing_candidates[#{index}].rejection_reasons[#{reason_index}]",
            reason,
            REFERENCE_CANDIDATE_REJECTION_REASONS
          )
        end
        validate_unique_array(
          "expected.reference_pricing_candidates[#{index}].rejection_reasons",
          candidate["rejection_reasons"]
        )
        validate_array(
          "expected.reference_pricing_candidates[#{index}].rounding_matches",
          candidate["rounding_matches"],
          maximum: MAX_ROUNDING_MATCHES
        ) do |rounding_match, rounding_index|
          validate_inclusion(
            "expected.reference_pricing_candidates[#{index}].rounding_matches[#{rounding_index}]",
            rounding_match,
            ROUNDING_MATCHES
          )
        end unless candidate["rounding_matches"].nil?
        validate_unique_array(
          "expected.reference_pricing_candidates[#{index}].rounding_matches",
          candidate["rounding_matches"]
        )
        %w[reference_price_amount reference_quantity purchased_quantity].each do |field|
          validate_bounded_decimal_token(
            "expected.reference_pricing_candidates[#{index}].#{field}",
            candidate[field]
          )
        end
        %w[reference_unit_code purchased_unit_code].each do |field|
          validate_bounded_token(
            "expected.reference_pricing_candidates[#{index}].#{field}",
            candidate[field]
          )
        end
        validate_bounded_non_negative_integer(
          "expected.reference_pricing_candidates[#{index}].projected_line_total",
          candidate["projected_line_total"],
          maximum: MeasurementContract::MAX_LINE_TOTAL
        )
        validate_bounded_integer_token(
          "expected.reference_pricing_candidates[#{index}].printed_line_total",
          candidate["printed_line_total"],
          maximum: MeasurementContract::MAX_LINE_TOTAL
        )
        validate_optional_inclusion(
          "expected.reference_pricing_candidates[#{index}].reference_price_tax_inclusion",
          candidate["reference_price_tax_inclusion"],
          TAX_INCLUSIONS + [ "unknown" ]
        )
      end
    end

    def validate_non_receipt_schema
      return unless expected.is_a?(Hash)

      validate_bounded_text("expected.status", expected["status"])
      validate_bounded_text_array("expected.review_reasons", expected["review_reasons"])
      validate_optional_bounded_text(
        "expected.processing_error_code",
        expected["processing_error_code"]
      )
    end

    def validate_receipt_expected_values
      %w[store_name store_address].each do |field|
        validate_bounded_text("expected.#{field}", expected[field], allow_line_breaks: true)
      end
      %w[purchased_at currency payment_method status].each do |field|
        validate_bounded_text("expected.#{field}", expected[field])
      end
      validate_optional_bounded_text(
        "expected.processing_error_code",
        expected["processing_error_code"]
      )
      validate_optional_number("expected.tax_rate", expected["tax_rate"])
      %w[subtotal tax total payment_sum].each do |field|
        validate_integer("expected.#{field}", expected[field])
      end
      validate_bounded_text_array("expected.review_reasons", expected["review_reasons"])

      settlement = expected["settlement"]
      return unless settlement.is_a?(Hash)

      validate_optional_integer("expected.settlement.tendered", settlement["tendered"])
      validate_optional_integer("expected.settlement.change", settlement["change"])
      validate_optional_bounded_text(
        "expected.settlement.payment_label",
        settlement["payment_label"],
        allow_line_breaks: true
      )
    end

    def validate_render_values
      render = case_data["render"]
      return unless render.is_a?(Hash)

      %w[locale paper_width font].each do |field|
        validate_optional_bounded_text("render.#{field}", render[field])
      end
      %w[include_tax_detail_lines omit_subtotal_line include_payment_heading].each do |field|
        validate_optional_boolean("render.#{field}", render[field])
      end
      %w[noise_lines custom_lines].each do |field|
        next unless render.key?(field)

        validate_bounded_text_array("render.#{field}", render[field])
      end
    end

    def validate_assertion_values
      assertions = case_data["assertions"]
      return unless assertions.is_a?(Hash)

      critical_exact = assertions["critical_exact"]
      if critical_exact.is_a?(Array)
        validate_bounded_text_array("assertions.critical_exact", critical_exact)
      elsif !critical_exact.nil? && critical_exact != true && critical_exact != false
        add_error("assertions.critical_exact", "must be a boolean or an array of bounded strings")
      end
      if assertions.key?("allow_review_reasons")
        validate_bounded_text_array(
          "assertions.allow_review_reasons",
          assertions["allow_review_reasons"]
        )
      end
      validate_optional_boolean(
        "assertions.allow_item_name_minor_diff",
        assertions["allow_item_name_minor_diff"]
      )
      validate_optional_number(
        "assertions.simulated_ai_item_tax_rate",
        assertions["simulated_ai_item_tax_rate"]
      )
      validate_optional_number(
        "assertions.expected_item_tax_rate_after_save",
        assertions["expected_item_tax_rate_after_save"]
      )
    end

    def validate_degradation
      degradation = case_data["degradation"]
      return unless degradation.is_a?(Hash)

      validate_boolean("degradation.enabled", degradation["enabled"])
      return if degradation["profile"].nil?

      validate_inclusion("degradation.profile", degradation["profile"], DegradationProfiles.names)
    end

    def validate_amounts
      if case_data["source"]
        validate_measurement_contract
      else
        validate_item_line_totals
      end
      validate_adjustments
      validate_tax_details
      validate_receipt_totals
      validate_payments
      validate_receipt_tax_rate
    end

    def validate_item_line_totals
      expected["items"].each_with_index do |item, index|
        unit_price = decimal(item["unit_price"])
        quantity = decimal(item["quantity"])
        discount = amount(item["discount_amount"])
        computed = unit_price * quantity - discount
        add_error("expected.items[#{index}].line_total", "must equal unit_price * quantity - discount_amount (#{integer_string(computed)})") unless integer_amount?(computed, item["line_total"])
      end
    end

    def validate_measurement_contract
      source_items = Array(case_data.dig("source", "items"))
      projections = Array(expected["measurement_projections"])
      candidate_expectations = Array(expected["reference_pricing_candidates"])
      expected_items = Array(expected["items"])

      validate_unique_item_indexes("source.items", source_items)
      validate_unique_item_indexes("expected.measurement_projections", projections)
      validate_unique_item_indexes("expected.reference_pricing_candidates", candidate_expectations)
      expected_item_indexes = (0...expected_items.size).to_a
      source_item_indexes = source_items.map { |entry| entry["item_index"] }.sort
      unless source_item_indexes == expected_item_indexes
        add_error("source.items", "item indexes must exactly cover expected.items")
      end
      validate_matching_item_indexes(
        "expected.measurement_projections",
        source_items,
        projections
      )
      validate_matching_item_indexes(
        "expected.reference_pricing_candidates",
        source_items,
        candidate_expectations
      )

      source_items.each_with_index do |source_item, source_index|
        item_index = source_item["item_index"]
        expected_item = expected_items[item_index] if item_index.is_a?(Integer)
        projection = projections.find { |entry| entry["item_index"] == item_index }
        candidate = candidate_expectations.find { |entry| entry["item_index"] == item_index }

        unless expected_item
          add_error("source.items[#{source_index}].item_index", "must identify an expected item")
          next
        end
        add_error("expected.measurement_projections", "is missing item_index #{item_index}") unless projection
        add_error("expected.reference_pricing_candidates", "is missing item_index #{item_index}") unless candidate

        validate_candidate_source(candidate, source_item, expected_item, source_index) if candidate
        validate_context_authority(source_item, expected_item, projection, item_index)
        validate_projected_discount(expected_item, projection, item_index)
        validate_printed_line_total(source_item, expected_item, item_index)
        validate_independent_projection(source_item, expected_item, projection, item_index, source_index) if projection
      end
    end

    def validate_unique_item_indexes(path, entries)
      indexes = entries.filter_map { |entry| entry["item_index"] if entry.is_a?(Hash) }
      indexes.tally.each do |item_index, count|
        add_error(path, "has duplicate item_index #{item_index}") if count > 1
      end
    end

    def validate_matching_item_indexes(path, source_items, entries)
      source_indexes = source_items.filter_map { |entry| entry["item_index"] if entry.is_a?(Hash) }.sort
      entry_indexes = entries.filter_map { |entry| entry["item_index"] if entry.is_a?(Hash) }.sort
      return if entry_indexes == source_indexes

      add_error(path, "item indexes must exactly match source.items")
    end

    def validate_candidate_source(candidate, source_item, expected_item, source_index)
      path = "expected.reference_pricing_candidates[#{candidate_index(candidate['item_index'])}]"
      state = candidate["validation_state"]
      reasons = Array(candidate["rejection_reasons"])
      if %w[valid none].include?(state)
        add_error("#{path}.rejection_reasons", "must be empty for #{state}") if reasons.any?
      elsif reasons.empty?
        add_error("#{path}.rejection_reasons", "must identify why #{state} is not valid")
      end

      computed = independent_measurement_projection(source_item, expected_item)
      if state == "none"
        if computed || explicit_reference_evidence?(source_item)
          add_error(
            "#{path}.validation_state",
            "cannot be none for an independently projectable source"
          )
        end
        if (candidate.keys - REFERENCE_CANDIDATE_REQUIRED_KEYS).any?
          add_error(path, "must not include source fields when validation_state is none")
        end
        return
      end

      {
        "reference_price_amount" => "reference_price_amount",
        "reference_quantity" => "reference_quantity",
        "reference_unit_code" => "reference_unit",
        "purchased_quantity" => "purchased_quantity",
        "purchased_unit_code" => "purchased_unit",
        "reference_price_tax_inclusion" => "reference_price_tax_inclusion"
      }.each do |candidate_field, source_field|
        next if equivalent_source_value?(candidate_field, candidate[candidate_field], source_item[source_field])

        add_error(
          "#{path}.#{candidate_field}",
          "must match source.items[#{source_index}].#{source_field}"
        )
      end

      expected_printed_total = source_item["printed_line_total"]&.to_i
      actual_printed_total = candidate["printed_line_total"]&.to_i
      unless actual_printed_total == expected_printed_total
        add_error("#{path}.printed_line_total", "must match source.items[#{source_index}].printed_line_total")
      end

      if state == "valid" && (!computed || computed.projected_gross_line_total.nil?)
        add_error("#{path}.validation_state", "cannot be valid without an independently projectable source")
      end
      if computed && candidate["projected_line_total"] != computed.projected_reference_line_total
        add_error(
          "#{path}.projected_line_total",
          "must match the independent Measurement projection"
        )
      end
      expected_rounding_matches = MeasurementContract.rounding_matches(
        exact_amount: computed&.exact_reference_amount,
        printed_line_total: source_item["printed_line_total"]
      )
      unless Array(candidate["rounding_matches"]) == expected_rounding_matches
        add_error(
          "#{path}.rounding_matches",
          "must match independently computed item-end rounding corroboration"
        )
      end
    end

    def explicit_reference_evidence?(source_item)
      %w[reference_price_amount reference_quantity reference_unit].any? do |field|
        !source_item[field].nil?
      end
    end

    def independent_measurement_projection(source_item, expected_item)
      MeasurementContract.project(
        source_item: source_item,
        tax_rate: expected_item["tax_rate"],
        tax_rounding: expected.dig("rounding", "tax"),
        discount_rounding: expected.dig("rounding", "discount")
      )
    end

    def equivalent_source_value?(candidate_field, candidate_value, source_value)
      if %w[reference_price_amount reference_quantity purchased_quantity].include?(candidate_field)
        equivalent_exact_decimal?(candidate_value, source_value)
      else
        candidate_value == source_value
      end
    end

    def candidate_index(item_index)
      Array(expected["reference_pricing_candidates"]).index { |entry| entry["item_index"] == item_index } || item_index
    end

    def validate_context_authority(source_item, expected_item, projection, item_index)
      validate_purchased_source(source_item, expected_item, item_index)

      case case_data.dig("source", "context")
      when "analysis"
        validate_analysis_candidate_persistence(expected_item, item_index)
        validate_analysis_item_total(source_item, expected_item, item_index)
      when "manual", "edit_save"
        validate_manual_or_edit_authority(source_item, expected_item, projection, item_index)
      end
    end

    def validate_analysis_item_total(source_item, expected_item, item_index)
      printed_total = source_item["printed_line_total"]
      unless printed_total.nil?
        %w[original_line_total line_total].each do |field|
          next if expected_item[field] == printed_total

          add_error(
            "expected.items[#{item_index}].#{field}",
            "must preserve printed_line_total #{printed_total}"
          )
        end
        return
      end

      %w[original_line_total line_total].each do |field|
        next if expected_item[field].nil?

        add_error(
          "expected.items[#{item_index}].#{field}",
          "must remain null when analysis has no printed item total"
        )
      end
    end

    def validate_purchased_source(source_item, expected_item, item_index)
      {
        "quantity" => "purchased_quantity",
        "quantity_unit_code" => "purchased_unit"
      }.each do |item_field, source_field|
        next if equivalent_persisted_source_value?(item_field, expected_item[item_field], source_item[source_field])

        add_error(
          "expected.items[#{item_index}].#{item_field}",
          "must match source.items[#{item_index}].#{source_field}"
        )
      end
    end

    def validate_projected_discount(expected_item, projection, item_index)
      return unless projection

      projected_discount = projection["discount_amount"]
      return if expected_item["discount_amount"] == projected_discount

      add_error(
        "expected.items[#{item_index}].discount_amount",
        "must equal the independently projected discount #{projected_discount}"
      )
    end

    def validate_manual_or_edit_authority(source_item, expected_item, projection, item_index)
      case expected_item["pricing_source_kind"]
      when "reference_quantity_price"
        validate_reference_authority(source_item, expected_item, projection, item_index)
      when "explicit_line_total"
        validate_explicit_authority(source_item, expected_item, item_index)
      else
        add_error(
          "expected.items[#{item_index}].pricing_source_kind",
          "must declare reference or explicit authority for a Measurement source"
        )
      end
    end

    def validate_reference_authority(source_item, expected_item, projection, item_index)
      return unless projection

      context = case_data.dig("source", "context")
      allowed_inclusions = context == "manual" ? [ "gross" ] : TAX_INCLUSIONS
      inclusion = source_item["reference_price_tax_inclusion"]
      unless allowed_inclusions.include?(inclusion)
        expected_basis = context == "manual" ? "gross" : "gross or net"
        add_error(
          "source.items[#{item_index}].reference_price_tax_inclusion",
          "must be #{expected_basis} for #{context} reference authority"
        )
      end
      computed = independent_measurement_projection(source_item, expected_item)
      unless computed && !computed.projected_gross_line_total.nil?
        add_error(
          "source.items[#{item_index}]",
          "must be independently projectable for #{context} reference authority"
        )
      end

      {
        "reference_price_amount" => "reference_price_amount",
        "reference_quantity" => "reference_quantity",
        "reference_quantity_unit_code" => "reference_unit",
        "reference_price_tax_inclusion" => "reference_price_tax_inclusion"
      }.each do |item_field, source_field|
        next if equivalent_persisted_source_value?(item_field, expected_item[item_field], source_item[source_field])

        add_error(
          "expected.items[#{item_index}].#{item_field}",
          "must match source.items[#{item_index}].#{source_field}"
        )
      end

      expected_values = {
        "original_line_total" => projection["projected_reference_line_total"],
        "line_total" => projection["discounted_source_line_total"]
      }
      expected_values.each do |field, projected_value|
        next if expected_item[field] == projected_value

        add_error(
          "expected.items[#{item_index}].#{field}",
          "must equal the independently projected persisted source amount #{projected_value}"
        )
      end
    end

    def validate_explicit_authority(source_item, expected_item, item_index)
      printed_total = source_item["printed_line_total"]
      if printed_total.nil?
        add_error(
          "source.items[#{item_index}].printed_line_total",
          "is required for explicit authority"
        )
        return
      end

      %w[original_line_total line_total].each do |field|
        next if expected_item[field] == printed_total

        add_error(
          "expected.items[#{item_index}].#{field}",
          "must preserve explicit printed_line_total #{printed_total}"
        )
      end
    end

    def equivalent_persisted_source_value?(item_field, item_value, source_value)
      if %w[reference_price_amount reference_quantity quantity].include?(item_field)
        equivalent_exact_decimal?(item_value, source_value)
      else
        item_value == source_value
      end
    end

    def equivalent_exact_decimal?(left_value, right_value)
      left = normalize_exact_decimal(left_value)
      right = normalize_exact_decimal(right_value)
      return false if left == :invalid_exact_decimal || right == :invalid_exact_decimal

      left == right
    end

    def normalize_exact_decimal(value)
      return nil if value.nil?

      token = bounded_numeric_token(value)
      return :invalid_exact_decimal unless token&.match?(EXACT_DECIMAL_PATTERN)

      BigDecimal(token).to_s("F")
    rescue ArgumentError, TypeError, FloatDomainError, EncodingError
      :invalid_exact_decimal
    end

    def validate_analysis_candidate_persistence(item, item_index)
      source_fields = %w[
        pricing_source_kind
        reference_price_amount
        reference_quantity
        reference_quantity_unit_code
        reference_price_tax_inclusion
      ]
      source_fields.each do |field|
        next if item[field].nil?

        message = if field == "pricing_source_kind"
          "must remain null for analysis candidate-only cases"
        else
          "must remain null when OCR candidate automatic adoption is disabled"
        end
        add_error("expected.items[#{item_index}].#{field}", message)
      end
    end

    def validate_printed_line_total(source_item, expected_item, item_index)
      return unless source_item.key?("printed_line_total")

      printed_total = source_item["printed_line_total"]
      return if printed_total.nil? && expected_item["line_total"].nil?
      return if amount(printed_total) == amount(expected_item["line_total"])

      add_error(
        "expected.items[#{item_index}].line_total",
        "must preserve printed_line_total #{printed_total.inspect}"
      )
    end

    def validate_independent_projection(source_item, expected_item, projection, item_index, source_index)
      computed = MeasurementContract.project(
        source_item: source_item,
        tax_rate: expected_item["tax_rate"],
        tax_rounding: expected.dig("rounding", "tax"),
        discount_rounding: expected.dig("rounding", "discount")
      )
      path = "expected.measurement_projections[#{projection_index(item_index)}]"

      if computed.nil?
        %w[
          exact_reference_amount
          projected_reference_line_total
          discount_amount
          discounted_source_line_total
          projected_gross_line_total
        ].each do |field|
          add_error("#{path}.#{field}", "must be null when the source is not independently projectable") unless projection[field].nil?
        end
        return
      end

      if source_item.key?("discount_amount") && !source_item["discount_amount"].nil? &&
          amount(source_item["discount_amount"]) != computed.discount_amount
        add_error(
          "source.items[#{source_index}].discount_amount",
          "must equal the independently projected discount #{computed.discount_amount}"
        )
      end

      validate_exact_amount("#{path}.exact_reference_amount", projection["exact_reference_amount"], computed.exact_reference_amount)
      {
        "projected_reference_line_total" => computed.projected_reference_line_total,
        "discount_amount" => computed.discount_amount,
        "discounted_source_line_total" => computed.discounted_source_line_total,
        "projected_gross_line_total" => computed.projected_gross_line_total
      }.each do |field, expected_value|
        next if projection[field] == expected_value

        add_error("#{path}.#{field}", "must equal independently computed #{expected_value.inspect}")
      end
    end

    def projection_index(item_index)
      Array(expected["measurement_projections"]).index { |entry| entry["item_index"] == item_index } || item_index
    end

    def validate_exact_amount(path, value, exact_amount)
      expected_value = {
        "numerator" => exact_amount.numerator.to_s,
        "denominator" => exact_amount.denominator.to_s
      }
      return if value == expected_value

      add_error(path, "must equal independently computed #{expected_value.inspect}")
    end

    def validate_adjustments
      expected["receipt_adjustments"].each_with_index do |adjustment, index|
        add_error("expected.receipt_adjustments[#{index}].amount", "must be positive") unless amount(adjustment["amount"]).positive?
        next unless adjustment["effect"] == "purchase"

        add_error("expected.receipt_adjustments[#{index}].tax_rate", "is required for purchase adjustments") if adjustment["tax_rate"].nil?
      end
    end

    def validate_tax_details
      if expected["tax_details"].empty?
        validate_zero_tax_without_tax_details
        return
      end

      expected["tax_details"].each_with_index do |detail, index|
        net = amount(detail["net"])
        tax = amount(detail["tax"])
        gross = amount(detail["gross"])
        add_error("expected.tax_details[#{index}].gross", "must equal net + tax") unless gross == net + tax

        rate = decimal(detail["rate"])
        computed_tax = if detail["basis"] == "gross"
          round_tax(decimal(gross) * rate / (BigDecimal("1") + rate))
        else
          round_tax(decimal(net) * rate)
        end
        add_error("expected.tax_details[#{index}].tax", "must equal #{computed_tax} for #{detail['basis']} basis") unless tax == computed_tax
      end

      expected_groups = expected_tax_groups
      expected_groups.delete(rate_key(0)) if zero_tax_detail_omitted?
      actual_groups = expected["tax_details"].each_with_object({}) do |detail, groups|
        rate_key = rate_key(detail["rate"])
        groups[rate_key] ||= { "net" => 0, "tax" => 0, "gross" => 0 }
        groups[rate_key]["net"] += amount(detail["net"])
        groups[rate_key]["tax"] += amount(detail["tax"])
        groups[rate_key]["gross"] += amount(detail["gross"])
      end

      expected_groups.each do |rate, values|
        actual = actual_groups[rate] || { "net" => 0, "tax" => 0, "gross" => 0 }
        %w[net tax gross].each do |key|
          add_error("expected.tax_details[rate=#{rate}].#{key}", "must equal computed #{values[key]}") unless actual[key] == values[key]
        end
      end
      extra_rates = actual_groups.keys - expected_groups.keys
      extra_rates.each { |rate| add_error("expected.tax_details", "has unexpected rate #{rate}") }
    end

    def validate_receipt_totals
      if expected["tax_details"].empty?
        validate_zero_tax_receipt_totals if zero_tax_without_tax_details?
        return
      end

      omitted_zero_tax_total = zero_tax_detail_omitted? ? zero_tax_purchase_total : 0
      net_sum = expected["tax_details"].sum { |detail| amount(detail["net"]) } + omitted_zero_tax_total
      tax_sum = expected["tax_details"].sum { |detail| amount(detail["tax"]) }
      gross_sum = expected["tax_details"].sum { |detail| amount(detail["gross"]) } + omitted_zero_tax_total

      add_error("expected.subtotal", "must equal tax_detail net sum #{net_sum}") unless amount(expected["subtotal"]) == net_sum
      add_error("expected.tax", "must equal tax_detail tax sum #{tax_sum}") unless amount(expected["tax"]) == tax_sum
      add_error("expected.total", "must equal tax_detail gross sum #{gross_sum}") unless amount(expected["total"]) == gross_sum
    end

    def validate_payments
      payment_sum = expected["payments"].sum { |payment| amount(payment["amount"]) }
      add_error("expected.payment_sum", "must equal payments sum #{payment_sum}") unless amount(expected["payment_sum"]) == payment_sum

      due = amount(expected["total"]) + payment_adjustment_total
      add_error("expected.payment_sum", "must equal total plus payment adjustments #{due}") unless payment_sum == due

      settlement = expected["settlement"]
      return if settlement.nil?

      tendered = amount(settlement["tendered"])
      change = amount(settlement["change"])
      actual_cash = expected["payments"].select { |payment| payment["method"] == "cash" }.sum { |payment| amount(payment["amount"]) }
      computed_cash = tendered - change
      add_error("expected.settlement", "tendered - change must equal cash payment #{actual_cash}") unless computed_cash == actual_cash
    end

    def validate_receipt_tax_rate
      rates = expected["tax_details"].filter_map do |detail|
        rate = decimal(detail["rate"])
        rate.zero? ? nil : rate_key(rate)
      end.uniq

      if rates.size == 1
        add_error("expected.tax_rate", "must equal #{rates.first} for a single taxable rate") unless rate_key(expected["tax_rate"]) == rates.first
      elsif rates.size > 1
        add_error("expected.tax_rate", "must be null for multiple taxable rates") unless expected["tax_rate"].nil?
      end
    end

    def expected_tax_groups
      bases = Hash.new { |hash, key| hash[key] = { "net_base" => 0, "gross_base" => 0 } }

      expected["items"].each do |item|
        rate = rate_key(item["tax_rate"])
        inclusion = item["tax_inclusion"] || default_tax_inclusion
        bases[rate]["#{inclusion}_base"] += amount(item["line_total"])
      end

      expected["receipt_adjustments"].select { |adjustment| adjustment["effect"] == "purchase" }.each do |adjustment|
        rate = rate_key(adjustment["tax_rate"])
        inclusion = adjustment["tax_inclusion"] || default_tax_inclusion
        bases[rate]["#{inclusion}_base"] += signed_amount(adjustment)
      end

      bases.each_with_object({}) do |(rate_key, base), groups|
        gross_base = base["gross_base"]
        net_base = base["net_base"]
        rate = decimal_from_rate_key(rate_key)

        gross_tax = round_tax(decimal(gross_base) * rate / (BigDecimal("1") + rate))
        net_tax = round_tax(decimal(net_base) * rate)
        groups[rate_key] = {
          "net" => (gross_base - gross_tax) + net_base,
          "tax" => gross_tax + net_tax,
          "gross" => gross_base + net_base + net_tax
        }
      end
    end

    def receipt_case?
      case_data["receipt_kind"] == "receipt"
    end

    def expected_required_keys
      receipt_case? ? EXPECTED_REQUIRED_KEYS : NON_RECEIPT_EXPECTED_REQUIRED_KEYS
    end

    def validate_zero_tax_without_tax_details
      return if zero_tax_without_tax_details?

      add_error("expected.tax_details", "may be empty only when every purchase line is zero-tax and expected.tax is 0")
    end

    def validate_zero_tax_receipt_totals
      total = zero_tax_purchase_total

      add_error("expected.subtotal", "must equal zero-tax purchase total #{total}") unless amount(expected["subtotal"]) == total
      add_error("expected.tax", "must equal 0 for zero-tax receipts without tax details") unless amount(expected["tax"]).zero?
      add_error("expected.total", "must equal zero-tax purchase total #{total}") unless amount(expected["total"]) == total
    end

    def zero_tax_without_tax_details?
      expected["tax_details"].empty? &&
        amount(expected["tax"]).zero? &&
        expected["items"].all? { |item| decimal(item["tax_rate"]).zero? } &&
        expected["receipt_adjustments"].select { |adjustment| adjustment["effect"] == "purchase" }.all? { |adjustment| decimal(adjustment["tax_rate"]).zero? }
    end

    def zero_tax_purchase_total
      item_total = expected["items"].select { |item| decimal(item["tax_rate"]).zero? }.sum { |item| amount(item["line_total"]) }
      purchase_adjustment_total = expected["receipt_adjustments"].select do |adjustment|
        adjustment["effect"] == "purchase" && decimal(adjustment["tax_rate"]).zero?
      end.sum { |adjustment| signed_amount(adjustment) }

      item_total + purchase_adjustment_total
    end

    def zero_tax_detail_omitted?
      zero_tax_purchase_total.positive? &&
        expected["tax_details"].none? { |detail| decimal(detail["rate"]).zero? }
    end

    def expected
      case_data["expected"] || {}
    end

    def default_tax_inclusion
      expected["amount_basis"] == "tax_excluded" ? "net" : "gross"
    end

    def validate_mixed_tax_inclusion(path, value)
      return unless expected["amount_basis"] == "mixed"
      return if TAX_INCLUSIONS.include?(value)

      add_error(path, "is required when expected.amount_basis is mixed")
    end

    def payment_adjustment_total
      expected["receipt_adjustments"].select { |adjustment| adjustment["effect"] == "payment" }.sum { |adjustment| signed_amount(adjustment) }
    end

    def signed_amount(adjustment)
      value = amount(adjustment["amount"])
      adjustment["sign"] == "surcharge" ? value : -value
    end

    def round_tax(value)
      case expected.dig("rounding", "tax")
      when "ceil"
        value.ceil
      when "round"
        value.round(0, :half_up).to_i
      else
        value.floor
      end
    end

    def validate_hash(path, value, required:, allowed:)
      unless value.is_a?(Hash)
        add_error(path, "must be an object")
        return
      end

      required.each do |key|
        add_error("#{path}.#{key}", "is required") unless value.key?(key)
      end
      add_error(path, "has more than #{MAX_OBJECT_KEYS} keys") if value.size > MAX_OBJECT_KEYS
      value.each_key.first(MAX_OBJECT_KEYS).each do |key|
        next if allowed.include?(key)

        add_error("#{path}.#{safe_error_segment(key)}", "is not allowed")
      end
    end

    def validate_case_id
      return if self.class.valid_case_id?(case_data["case_id"])

      add_error("case_id", "must be a path-safe generated receipt identifier")
    end

    def validate_optional_hash(path, value, allowed:)
      return if value.nil?

      validate_hash(path, value, required: [], allowed: allowed)
    end

    def validate_array(path, value, maximum: MAX_COLLECTION_ITEMS)
      unless value.is_a?(Array)
        add_error(path, "must be an array")
        return
      end

      add_error(path, "has more than #{maximum} entries") if value.size > maximum
      return unless block_given?

      value.first(maximum).each_with_index { |entry, index| yield entry, index }
    end

    def validate_inclusion(path, value, allowed)
      add_error(path, "must be one of #{allowed.join(', ')}") unless allowed.include?(value)
    end

    def validate_unique_array(path, value)
      return unless value.is_a?(Array)
      return if value.first(MAX_COLLECTION_ITEMS).uniq.size == value.first(MAX_COLLECTION_ITEMS).size

      add_error(path, "must contain unique values")
    end

    def validate_optional_inclusion(path, value, allowed)
      return if value.nil?

      validate_inclusion(path, value, allowed)
    end

    def add_error(path, message)
      return if errors.size >= MAX_ERRORS

      errors << "#{path}: #{message}"
    end

    def decimal(value)
      token = bounded_numeric_token(value)
      return BigDecimal(token) if token&.match?(EXACT_DECIMAL_PATTERN)

      add_error("amount", "invalid or oversized decimal value")
      BigDecimal("0")
    rescue ArgumentError, TypeError, FloatDomainError, EncodingError
      add_error("amount", "invalid or oversized decimal value")
      BigDecimal("0")
    end

    def amount(value)
      decimal(value).to_i
    end

    def integer_amount?(computed, actual)
      computed.frac.zero? && computed.to_i == amount(actual)
    end

    def integer_string(value)
      value.frac.zero? ? value.to_i.to_s : value.to_s("F")
    end

    def rate_key(value)
      return nil if value.nil?

      decimal(value).to_s("F")
    end

    def decimal_from_rate_key(value)
      decimal(value)
    end

    def validate_item_index(path, value)
      return if value.is_a?(Integer) && value.between?(0, MAX_ITEM_INDEX)

      add_error(path, "must be an integer between 0 and #{MAX_ITEM_INDEX}")
    end

    def validate_printed_lines(path, value)
      return unless value.is_a?(Array)

      bounded_lines = value.first(MAX_PRINTED_LINES)
      if bounded_lines.empty?
        add_error(path, "must contain at least one non-empty string")
        return
      end

      unless bounded_lines.all? { |line| safe_source_line?(line) }
        add_error(
          path,
          "must contain bounded UTF-8 strings without control characters"
        )
      end
      total_bytes = bounded_lines.sum { |line| line.is_a?(String) ? line.bytesize : 0 }
      if total_bytes > MAX_SOURCE_ITEM_BYTES
        add_error(path, "must contain at most #{MAX_SOURCE_ITEM_BYTES} bytes per item")
      end
    end

    def safe_source_line?(value)
      return false unless value.is_a?(String)
      return false if value.empty? || value.bytesize > MAX_SOURCE_LINE_BYTES
      return false unless safe_string?(value)

      true
    end

    def validate_bounded_token(path, value)
      return if value.nil?
      if value.is_a?(String) && !value.empty? && value.bytesize <= MAX_EXACT_TOKEN_BYTES && safe_string?(value)
        return
      end

      add_error(path, "must be a bounded string without control characters")
    end

    def validate_bounded_decimal_token(path, value, allow_numeric: false)
      return if value.nil?

      token = bounded_exact_token(value, allow_numeric: allow_numeric)
      return if token && token.match?(EXACT_DECIMAL_PATTERN)

      add_error(path, "must be an exact decimal within the approved bounds")
    end

    def validate_bounded_integer_token(path, value, maximum: nil)
      return if value.nil?

      token = bounded_exact_token(value, allow_numeric: false)
      valid = token&.match?(EXACT_INTEGER_PATTERN)
      valid &&= Integer(token, 10) <= maximum if valid && maximum
      return if valid

      add_error(path, "must be a bounded non-negative integer string")
    rescue ArgumentError
      add_error(path, "must be a bounded non-negative integer string")
    end

    def validate_bounded_non_negative_integer(path, value, maximum:)
      return if value.nil?
      return if value.is_a?(Integer) && value.between?(0, maximum)

      add_error(path, "must be an integer between 0 and #{maximum}")
    end

    def validate_bounded_text(path, value, allow_line_breaks: false)
      return if bounded_fixture_text?(value, allow_line_breaks: allow_line_breaks)

      add_error(path, "must be a bounded UTF-8 string")
    end

    def validate_optional_bounded_text(path, value, allow_line_breaks: false)
      return if value.nil?

      validate_bounded_text(path, value, allow_line_breaks: allow_line_breaks)
    end

    def validate_bounded_text_array(path, value)
      validate_array(path, value) do |entry, index|
        validate_bounded_text("#{path}[#{index}]", entry)
      end
    end

    def validate_boolean(path, value)
      return if value == true || value == false

      add_error(path, "must be a boolean")
    end

    def validate_optional_boolean(path, value)
      return if value.nil?

      validate_boolean(path, value)
    end

    def validate_number(path, value)
      valid = case value
      when Integer
        value.bit_length <= MAX_NUMERIC_BITS
      when Float
        value.finite?
      else
        false
      end
      return if valid

      add_error(path, "must be a bounded finite JSON number")
    end

    def validate_optional_number(path, value)
      return if value.nil?

      validate_number(path, value)
    end

    def validate_integer(path, value, maximum: nil)
      valid = value.is_a?(Integer) && value.bit_length <= MAX_NUMERIC_BITS
      valid &&= value.between?(0, maximum) if valid && maximum
      return if valid

      message = maximum ? "must be an integer between 0 and #{maximum}" : "must be a bounded integer"
      add_error(path, message)
    end

    def validate_optional_integer(path, value, maximum: nil)
      return if value.nil?

      validate_integer(path, value, maximum: maximum)
    end

    def bounded_exact_token(value, allow_numeric:)
      case value
      when String
        value if value.bytesize <= MAX_EXACT_TOKEN_BYTES && safe_string?(value) && value.ascii_only?
      when Integer
        return nil unless allow_numeric && value.bit_length <= MeasurementContract::MAX_INTEGER_BITS

        value.to_s
      when Float
        return nil unless allow_numeric && value.finite?

        value.to_s
      end
    end

    def bounded_numeric_token(value)
      case value
      when String
        return nil if value.empty? || value.bytesize > MAX_EXACT_TOKEN_BYTES
        return nil unless safe_string?(value) && value.ascii_only?

        value
      when Integer
        return nil if value.bit_length > MeasurementContract::MAX_EXACT_BITS

        value.to_s
      when Float
        return nil unless value.finite?

        value.to_s
      when BigDecimal
        return nil unless value.finite?
        return nil if value.precision > MAX_EXACT_TOKEN_BYTES || value.scale > MAX_EXACT_TOKEN_BYTES
        return nil if value.exponent.abs > MAX_EXACT_TOKEN_BYTES

        value.to_s("F")
      end
    end

    def safe_string?(value)
      return false unless value.is_a?(String) && value.valid_encoding?
      return false unless value.encoding == Encoding::UTF_8 || value.ascii_only?

      !value.match?(CONTROL_CHARACTER_PATTERN)
    rescue ArgumentError, EncodingError
      false
    end

    def bounded_fixture_text?(value, allow_line_breaks:)
      return false unless value.is_a?(String)
      return false if value.bytesize > MAX_FIXTURE_TEXT_BYTES
      return false unless value.valid_encoding?
      return false unless value.encoding == Encoding::UTF_8 || value.ascii_only?

      pattern = allow_line_breaks ? FIXTURE_TEXT_CONTROL_PATTERN : CONTROL_CHARACTER_PATTERN
      !value.match?(pattern)
    rescue ArgumentError, EncodingError
      false
    end

    def safe_error_segment(_value)
      "invalid_key"
    end
  end
end
