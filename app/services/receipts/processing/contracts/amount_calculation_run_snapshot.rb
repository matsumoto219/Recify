# frozen_string_literal: true

module Receipts::Processing::Contracts
  class AmountCalculationRunSnapshot
    SCHEMA_VERSION = "amount_calculation_run_snapshot_v1"
    MAX_BYTES = 1_048_576
    MAX_ROWS = 10_000
    MAX_SOURCE_COUNT = 1_000_000
    MAX_NUMBER = 999_999_999_999_999
    NUMBER_PATTERN = /\A-?(?:0|[1-9][0-9]{0,14})(?:\.[0-9]{1,112})?\z/.freeze
    ROUNDING_MODES = %w[floor round ceil].freeze
    ROUNDING_SCOPES = %w[per_tax_rate_group per_item per_receipt].freeze
    BASES = %w[
      receipt_input_preserved external_tax_from_receipt items_as_tax_excluded items_as_tax_included
      mixed_by_tax_rate_group printed_tax_details_gross printed_tax_details_net printed_tax_details_raw_sum
      incomplete_tax_details_receipt_tax
    ].freeze
    CANDIDATE_IDS = (
      %w[analysis_receipt_input manual_receipt_input edit_saved_input] +
      %w[mixed_by_tax_rate_group printed_tax_details_gross printed_tax_details_net printed_tax_details_raw_sum external_tax_from_receipt].product(ROUNDING_MODES).map { |parts| parts.join("/") } +
      [ "incomplete_tax_details_receipt_tax/floor" ] +
      %w[items_as_tax_included items_as_tax_excluded].product(ROUNDING_MODES, ROUNDING_SCOPES).map { |parts| parts.join("/") } +
      [ "items_as_tax_excluded" ].product(ROUNDING_MODES, ROUNDING_SCOPES, [ "original_line_total" ]).map { |parts| parts.join("/") }
    ).freeze
    REASONS = %w[
      total_mismatch total_amount_mismatch subtotal_amount_mismatch item_total_mismatch tax_amount_mismatch
      tax_detail_mismatch invalid_amount_relation payment_amount_mismatch tax_details_double_counted
      tax_detail_gross_item_mismatch unsupported_tax_detail_gross_basis adjustment_uncertain insufficient_data
      ocr_total_mismatch tax_detail_rate_mismatch tax_detail_incomplete tax_detail_partial item_tax_rate_group_uncertain
      zero_amount_item_incomplete discount_data_incomplete adjustment_tax_rate_missing price_tax_inclusion_uncertain
      competing_exact_basis_candidate mixed_basis_search_truncated calculation_profile_uncertain
      purchase_adjustment_tax_allocation_uncertain
    ].freeze
    SCORE_KEYS = %w[
      receipt_total_delta receipt_subtotal_delta receipt_tax_delta payment_delta receipt_input_item_delta
      warning_penalty hard_reject_penalty rounding_mode_penalty external_tax_exact_tax_bonus basis_penalty
    ].freeze
    TOTAL_KEYS = %w[
      total_amount subtotal_amount tax_amount tax_rate adjusted_item_total adjustment_discount_total
      adjustment_surcharge_total purchase_adjustment_total payment_adjustment_total payment_amount_sum
      final_payment_total adjustment_tax_rate_missing_total tax_detail_amount_basis
    ].freeze
    PROFILE_KEYS = %w[tax_rounding_mode discount_rounding_mode receipt_tax_basis item_amount_basis tax_detail_amount_basis].freeze
    CANDIDATE_KEYS = %w[
      candidate_id basis subtotal tax purchase_total final_payment_total purchase_adjustment_total
      payment_adjustment_total payment_amount_sum rounding_mode rounding_scope score score_breakdown warnings hard_reject_reasons
    ].freeze
    CANDIDATE_INTEGER_KEYS = %w[
      subtotal tax purchase_total final_payment_total purchase_adjustment_total payment_adjustment_total payment_amount_sum score
    ].freeze
    REQUIRED_CANDIDATE_KEYS = (CANDIDATE_KEYS - [ "payment_amount_sum" ]).freeze
    ENGINE_KEYS = %w[schema_version selected_candidate_id selected_basis selected_candidate_status no_safe_candidate].freeze
    REVIEW_KEYS = %w[
      needs_review review_reasons warnings warning_reasons mismatch_codes blocking_mismatch_codes warning_mismatch_codes
      selected_candidate_status safe_to_auto_complete
    ].freeze
    SAVED_PROFILE_KEYS = %w[
      schema_version context profile rounding_mode computed resolved score warnings mismatch_codes blocking_mismatch_codes
      warning_mismatch_codes selected_candidate_status safe_to_auto_complete amount_engine
    ].freeze
    ITEM_KEYS = %w[
      price quantity quantity_unit_code original_line_total line_total discount_amount discount_rate tax_rate
      amount_price_present amount_quantity_present amount_line_total_present amount_discount_amount_present
    ].freeze
    ASSIGNMENT_KEYS = %w[tax_rate basis net_amount tax_amount gross_amount].freeze
    EVIDENCE_KEYS = %w[
      source index rate basis formula amount printed_amount printed_amount_basis net_amount gross_amount tax_amount
      target_net_amount target_tax_amount target_gross_amount purchase_total final_payment_total payment_amount_sum payment_delta
      payment_amount_mismatch_suppressed suppressed_reason effect kind sign tax_rate tax_rate_source
    ].freeze
    ENUMS = {
      "context" => %w[analysis manual edit_save],
      "selected_candidate_status" => %w[accepted rejected],
      "selected_basis" => BASES,
      "rounding_mode" => ROUNDING_MODES,
      "rounding_scope" => ROUNDING_SCOPES,
      "tax_rounding_mode" => ROUNDING_MODES,
      "discount_rounding_mode" => ROUNDING_MODES,
      "receipt_tax_basis" => %w[total_includes_tax tax_added_to_subtotal],
      "item_amount_basis" => %w[line_total_as_recorded line_total_as_net mixed_by_tax_rate_group],
      "tax_detail_amount_basis" => %w[gross net unknown],
      "source" => %w[receipt_items receipt_tax_detail receipt_input receipt_adjustment receipt_payments amount_engine],
      "basis" => %w[gross net tax_only summary intermediate unknown tax_included tax_excluded non_taxable],
      "formula" => BASES,
      "printed_amount_basis" => %w[gross net tax_only summary intermediate unknown],
      "effect" => %w[purchase_adjustment payment_adjustment unknown_adjustment],
      "kind" => %w[receipt_discount coupon point_usage return_refund service_charge late_night_charge delivery_fee bag_fee handling_fee other],
      "sign" => %w[discount surcharge],
      "tax_rate_source" => %w[explicit inherited_single_rate unknown not_applicable],
      "suppressed_reason" => %w[tendered_like_overpayment],
      "quantity_unit_code" => %w[each item piece bag sheet unit box set gram kilogram milligram liter milliliter cubic_centimeter],
      "status" => %w[uploaded processing completed review_needed failed]
    }.freeze
    BOOLEAN_KEYS = %w[
      needs_review safe_to_auto_complete no_safe_candidate payment_amount_mismatch_suppressed amount_price_present
      amount_quantity_present amount_line_total_present amount_discount_amount_present
    ].freeze
    REASON_KEYS = %w[review_reasons warnings warning_reasons mismatch_codes blocking_mismatch_codes warning_mismatch_codes hard_reject_reasons].freeze
    UNAVAILABLE_REASONS = %w[limits_missing invalid_limits missing_diagnostics invalid_diagnostics mandatory_budget_exceeded].freeze
    OMISSION_REASONS = %w[count_limit byte_limit invalid_value comparison_items_not_retained].freeze
    LIMIT_RANGES = AmountCalculationSnapshotLimits::RANGES

    class Invalid < StandardError; end
    class MandatoryBudgetExceeded < StandardError; end

    class << self
      def build(amount_result:, saved_profile:, receipt_summary:, limits:)
        new.build(amount_result: amount_result, saved_profile: saved_profile, receipt_summary: receipt_summary, limits: limits)
      end

      def read(value)
        new(strict: true).read(value)
      end
    end

    def initialize(strict: false)
      @strict = strict
      @collections = []
      @stored_collections = {}
    end

    def build(amount_result:, saved_profile:, receipt_summary:, limits:)
      return unavailable("limits_missing") if limits.nil?

      @limits = normalized_limits(limits)
      return unavailable("invalid_limits") unless @limits
      return unavailable("missing_diagnostics") unless amount_result.is_a?(Hash) && amount_result.any?

      @snapshot = {
        "schema_version" => SCHEMA_VERSION,
        "state" => "available",
        "limits" => @limits,
        "engine" => build_engine(amount_result),
        "saved_profile" => normalize_saved_profile(saved_profile),
        "receipt_summary" => receipt_totals(receipt_summary),
        "omissions" => @collections.map { |collection| collection.fetch(:counts) }
      }
      return unavailable("mandatory_budget_exceeded") unless core_fits?

      fill_collections
      @snapshot["state"] = "partial" if @collections.any? { |collection| collection[:counts]["omitted_count"].positive? }
      @snapshot
    rescue Invalid
      unavailable("invalid_diagnostics")
    rescue MandatoryBudgetExceeded
      unavailable("mandatory_budget_exceeded")
    end

    def read(value)
      @read_budget = MAX_BYTES
      bounded_json!(value)
      exact_keys!(value, %w[schema_version state limits reason engine saved_profile receipt_summary omissions])
      invalid! unless value["schema_version"] == SCHEMA_VERSION
      if value["state"] == "unavailable"
        return read_unavailable(value)
      end
      invalid! unless %w[available partial].include?(value["state"])
      invalid! if value.key?("reason")

      @limits = normalized_limits(value["limits"])
      invalid! unless @limits
      result = {
        "schema_version" => SCHEMA_VERSION,
        "state" => value["state"],
        "limits" => @limits,
        "engine" => read_engine(value["engine"]),
        "saved_profile" => normalize_saved_profile(value["saved_profile"]),
        "receipt_summary" => receipt_totals(value["receipt_summary"]),
        "omissions" => read_omissions(value["omissions"])
      }
      invalid! unless result == value
      evidence_count = @stored_collections.sum { |path, count| evidence_path?(path) ? count : 0 }
      invalid! if evidence_count > @limits["evidence"]
      invalid! if JSON.generate(result).bytesize > @limits["max_bytes"]
      partial = result["omissions"].any? { |entry| entry["omitted_count"].positive? }
      invalid! unless (result["state"] == "partial") == partial
      result
    rescue Invalid, JSON::GeneratorError
      nil
    end

    private

    def unavailable(reason)
      {
        "schema_version" => SCHEMA_VERSION,
        "state" => "unavailable",
        "reason" => reason,
        "limits" => @limits
      }
    end

    def read_unavailable(value)
      invalid! unless value.keys.sort == %w[limits reason schema_version state]
      invalid! unless UNAVAILABLE_REASONS.include?(value["reason"])
      limits = value["limits"].nil? ? nil : normalized_limits(value["limits"])
      invalid! if value["limits"] && !limits
      {
        "schema_version" => SCHEMA_VERSION,
        "state" => "unavailable",
        "reason" => value["reason"].dup,
        "limits" => limits
      }
    end

    def normalized_limits(input)
      return nil unless input.is_a?(Hash) && input.size == LIMIT_RANGES.size

      LIMIT_RANGES.each_with_object({}) do |(key, range), result|
        value = field(input, key)
        return nil unless value.is_a?(Integer) && range.cover?(value)

        result[key] = value
      end
    rescue Invalid
      nil
    end

    def build_engine(input)
      invalid! unless [ true, false ].include?(field(input, "needs_review"))
      engine = field(input, "amount_engine")
      invalid! unless engine.is_a?(Hash)
      invalid! if field(engine, "selected_candidate") && !field(input, "review_reasons").is_a?(Array)
      result = {
        "context" => scalar("context", field(input, "context")),
        "rounding_mode" => rounding(field(input, "rounding_mode")),
        "computed" => amount_summary(field(input, "computed")),
        "resolved" => amount_summary(field(input, "resolved")),
        "review" => fields(input, REVIEW_KEYS).merge("warning_classification" => "unrecorded")
      }
      result["profile"] = normalize_profile(field(input, "calculation_profile"), "engine.profile") if field(input, "calculation_profile")
      result["score"] = number(field(input, "calculation_profile_score")) unless field(input, "calculation_profile_score").nil?
      result["amount_engine"] = build_candidates(engine)
      result
    end

    def build_candidates(input)
      result = candidate_header(input)
      source = collection_source(field(input, "candidates"))
      invalid! if source.size > 20
      selected = field(input, "selected_candidate")
      selected_id = result["selected_candidate_id"]
      if selected
        result["selected_candidate"] = candidate_summary(selected)
        invalid! unless result["selected_candidate"].fetch("candidate_id") == selected_id
        register_collection(result["selected_candidate"], "computed_items", selected, "selected.computed_items", :items)
        register_collection(result["selected_candidate"], "evidence", selected, "selected.evidence", :evidence)
      else
        invalid! if selected_id
      end
      ids = source.map { |candidate| scalar("candidate_id", field(candidate, "candidate_id")) }
      invalid! unless ids.uniq.size == ids.size
      result["candidates"] = source.first(@limits["candidates"]).map.with_index do |candidate, index|
        if field(candidate, "candidate_id").to_s == selected_id
          { "candidate_id" => selected_id.dup, "selected_candidate_ref" => true }
        else
          summary = candidate_summary(candidate)
          register_collection(summary, "evidence", candidate, "candidates[#{index}].evidence", :comparison)
          register_collection(summary, "computed_items", candidate, "candidates[#{index}].computed_items", :excluded)
          summary
        end
      end
      @collections << {
        counts: counts("candidates", source.size, result["candidates"].size, source.size > result["candidates"].size ? [ "count_limit" ] : []),
        type: :summary
      }
      result
    end

    def candidate_summary(input)
      invalid! unless REQUIRED_CANDIDATE_KEYS.all? { |key| !field(input, key).nil? }
      fields(input, CANDIDATE_KEYS) do |key, value|
        case key
        when "basis" then enum(value, BASES)
        when "score_breakdown" then fields(value, SCORE_KEYS) { |_name, score| integer_number(score) }
        else CANDIDATE_INTEGER_KEYS.include?(key) ? integer_number(value) : scalar(key, value)
        end
      end.tap { |result| invalid! unless result.key?("candidate_id") }
    end

    def candidate_header(input)
      result = fields(input, ENGINE_KEYS)
      invalid! unless result["schema_version"] == 1 && result.key?("no_safe_candidate")
      if result["selected_candidate_id"]
        invalid! unless %w[selected_basis selected_candidate_status].all? { |key| result.key?(key) }
      end
      result
    end

    def normalize_saved_profile(input)
      invalid! unless field(input, "schema_version") == 1
      invalid! unless %w[context rounding_mode computed resolved].all? { |key| !field(input, key).nil? }
      fields(input, SAVED_PROFILE_KEYS) do |key, value|
        case key
        when "profile" then normalize_profile(value, "saved_profile.profile")
        when "rounding_mode" then rounding(value)
        when "computed", "resolved" then fields(value, TOTAL_KEYS)
        when "amount_engine" then fields(value, ENGINE_KEYS)
        else scalar(key, value)
        end
      end
    end

    def normalize_profile(input, path)
      fields(input, PROFILE_KEYS + [ "item_amount_basis_assignments" ]) do |key, value|
        if key == "item_amount_basis_assignments"
          if @strict
            read_rows(value, :assignment, "#{path}.#{key}")
          else
            target = {}
            register_collection(target, key, input, "#{path}.#{key}", :assignment)
            target.fetch(key)
          end
        else
          scalar(key, value)
        end
      end
    end

    def amount_summary(input)
      invalid! unless input.is_a?(Hash)
      invalid! unless %w[total subtotal tax total_amount subtotal_amount tax_amount].any? { |key| !field(input, key).nil? }
      keys = TOTAL_KEYS + %w[total subtotal tax]
      fields(input, keys).transform_keys { |key| { "total" => "total_amount", "subtotal" => "subtotal_amount", "tax" => "tax_amount" }.fetch(key, key) }
    end

    def receipt_totals(input)
      invalid! unless field(input, "status")
      fields(input, %w[status total_amount subtotal_amount tax_amount tax_rate])
    end

    def rounding(input)
      invalid! unless %w[tax discount].all? { |key| !field(input, key).nil? }
      fields(input, %w[tax discount]) { |_key, value| enum(value, ROUNDING_MODES) }
    end

    def register_collection(target, key, input, path, type)
      source = collection_source(field(input, key))
      target[key] = [] unless type == :excluded
      @collections << {
        source: source, target: target[key], type: type, cursor: 0,
        counts: counts(path, source.size, 0, type == :excluded && source.any? ? [ "comparison_items_not_retained" ] : [])
      }
    end

    def counts(path, source, stored, reasons)
      {
        "path" => path,
        "source_count" => source,
        "stored_count" => stored,
        "omitted_count" => source - stored,
        "reasons" => reasons
      }
    end

    def collection_source(value)
      invalid! unless value.is_a?(Array) && value.size <= MAX_SOURCE_COUNT
      value
    end

    def core_fits?
      # Reserve bookkeeping growth before admitting optional rows. The bound is
      # independent of the upstream arrays and includes every omission record.
      @remaining_bytes = @limits["max_bytes"] - JSON.generate(@snapshot).bytesize - (@collections.size * 128) - 16
      @remaining_bytes >= 0
    end

    def fill_collections
      @item_count = 0
      @evidence_count = 0
      detailed = @collections.reject { |collection| %i[summary excluded].include?(collection[:type]) }
      # Preserve one row from each existing comparison before filling optional
      # selected detail; comparison tails are consequently omitted first.
      detailed.each { |collection| append_row(collection, required: true) if collection[:source].any? }
      %i[items evidence assignment comparison].each do |type|
        detailed.select { |collection| collection[:type] == type }.each do |collection|
          while collection[:cursor] < collection[:source].size
            break unless append_row(collection)
          end
        end
      end
    end

    def append_row(collection, required: false)
      type = collection[:type]
      cap = type == :items ? @limits["computed_items"] : @limits["evidence"]
      used = type == :items ? @item_count : @evidence_count
      return omit_collection(collection, "count_limit") if used >= cap || collection[:cursor] >= cap

      raw = collection[:source][collection[:cursor]]
      collection[:cursor] += 1
      row = detail_row(raw, type)
      unless row
        collection[:counts]["reasons"] |= [ "invalid_value" ]
        return true
      end
      row["snapshot_index"] = collection[:cursor] - 1
      bytes = JSON.generate(row).bytesize + (collection[:target].empty? ? 0 : 1)
      raise MandatoryBudgetExceeded if required && bytes > @remaining_bytes
      return omit_collection(collection, "byte_limit") if bytes > @remaining_bytes

      collection[:target] << row
      collection[:counts]["stored_count"] += 1
      collection[:counts]["omitted_count"] -= 1
      @remaining_bytes -= bytes
      type == :items ? @item_count += 1 : @evidence_count += 1
      true
    end

    def detail_row(value, type)
      keys = case type
      when :items then ITEM_KEYS
      when :assignment then ASSIGNMENT_KEYS
      else EVIDENCE_KEYS
      end
      keys += [ "snapshot_index" ] if @strict
      fields(value, keys).tap { |row| invalid! if row.empty? }
    rescue Invalid
      raise if @strict
      nil
    end

    def omit_collection(collection, reason)
      collection[:counts]["reasons"] |= [ reason ]
      false
    end

    def read_engine(input)
      keys = %w[context rounding_mode computed resolved review profile score amount_engine]
      exact_keys!(input, keys)
      invalid! unless %w[context rounding_mode computed resolved review amount_engine].all? { |key| input.key?(key) }
      fields(input, keys) do |key, value|
        case key
        when "rounding_mode" then rounding(value)
        when "computed", "resolved" then amount_summary(value)
        when "profile" then normalize_profile(value, "engine.profile")
        when "review"
          exact_keys!(value, REVIEW_KEYS + [ "warning_classification" ])
          invalid! unless value["warning_classification"] == "unrecorded"
          invalid! unless value["needs_review"] == true || value["needs_review"] == false
          invalid! if field(input["amount_engine"], "selected_candidate") && !value["review_reasons"].is_a?(Array)
          fields(value.except("warning_classification"), REVIEW_KEYS).merge("warning_classification" => "unrecorded")
        when "amount_engine" then read_candidates(value)
        else scalar(key, value)
        end
      end
    end

    def read_candidates(input)
      exact_keys!(input, ENGINE_KEYS + %w[selected_candidate candidates])
      result = candidate_header(input.slice(*ENGINE_KEYS))
      selected = input["selected_candidate"]
      if selected
        result["selected_candidate"] = read_candidate(selected, selected: true, path: "selected")
        invalid! unless selected["candidate_id"] == result["selected_candidate_id"]
      else
        invalid! if result["selected_candidate_id"]
      end
      candidates = input["candidates"]
      invalid! unless candidates.is_a?(Array) && candidates.size <= @limits["candidates"]
      result["candidates"] = candidates.map.with_index do |candidate, index|
        if candidate.is_a?(Hash) && candidate["selected_candidate_ref"] == true
          exact_keys!(candidate, %w[candidate_id selected_candidate_ref])
          invalid! unless selected && candidate["candidate_id"] == selected["candidate_id"]
          { "candidate_id" => scalar("candidate_id", candidate["candidate_id"]), "selected_candidate_ref" => true }
        else
          read_candidate(candidate, selected: false, path: "candidates[#{index}]")
        end
      end
      ids = result["candidates"].map { |candidate| candidate["candidate_id"] }
      invalid! unless ids.uniq.size == ids.size
      @stored_collections["candidates"] = result["candidates"].size
      result
    end

    def read_candidate(input, selected:, path:)
      detail_keys = selected ? %w[evidence computed_items] : [ "evidence" ]
      exact_keys!(input, CANDIDATE_KEYS + detail_keys)
      result = candidate_summary(input.slice(*CANDIDATE_KEYS))
      detail_keys.each do |key|
        result[key] = read_rows(input[key], key == "computed_items" ? :items : :evidence, "#{path}.#{key}")
      end
      @stored_collections["#{path}.computed_items"] = 0 unless selected
      result
    end

    def read_rows(rows, type, path)
      cap = type == :items ? @limits["computed_items"] : @limits["evidence"]
      invalid! unless rows.is_a?(Array) && rows.size <= cap
      result = rows.map { |row| detail_row(row, type) }
      indices = result.map { |row| row["snapshot_index"] }
      invalid! unless indices.all? { |index| index.is_a?(Integer) && index.between?(0, MAX_SOURCE_COUNT - 1) }
      invalid! unless indices.each_cons(2).all? { |left, right| left < right }
      @stored_collections[path] = rows.size
      (@stored_indices ||= {})[path] = indices
      result
    end

    def evidence_path?(path)
      path.end_with?(".evidence", ".item_amount_basis_assignments")
    end

    def read_omissions(input)
      invalid! unless input.is_a?(Array) && input.size <= 45
      stored = @stored_collections || {}
      paths = []
      result = input.map do |entry|
        exact_keys!(entry, %w[path source_count stored_count omitted_count reasons])
        path = entry["path"]
        invalid! unless stored.key?(path)
        paths << path
        %w[source_count stored_count omitted_count].each do |key|
          invalid! unless entry[key].is_a?(Integer) && entry[key].between?(0, MAX_SOURCE_COUNT)
        end
        invalid! unless entry["stored_count"] == stored[path]
        invalid! unless entry["source_count"] == entry["stored_count"] + entry["omitted_count"]
        invalid! if @stored_indices&.fetch(path, [])&.any? { |index| index >= entry["source_count"] }
        reasons = entry["reasons"]
        invalid! unless reasons.is_a?(Array) && reasons.size <= OMISSION_REASONS.size && reasons.uniq == reasons
        invalid! unless reasons.all? { |reason| OMISSION_REASONS.include?(reason) }
        invalid! unless entry["omitted_count"].zero? == reasons.empty?
        counts(path.dup, entry["source_count"], entry["stored_count"], reasons.map(&:dup))
      end
      invalid! unless paths.uniq.size == paths.size && paths.sort == stored.keys.sort
      result
    end

    def fields(input, keys)
      invalid! unless input.is_a?(Hash)
      exact_keys!(input, keys) if @strict
      keys.each_with_object({}) do |key, result|
        value = field(input, key)
        next if value.nil?

        result[key] = block_given? ? yield(key, value) : scalar(key, value)
      end
    end

    def field(input, key)
      invalid! unless input.is_a?(Hash)
      if input.key?(key)
        invalid! if input.key?(key.to_sym) && !input.is_a?(ActiveSupport::HashWithIndifferentAccess)
        input[key]
      else
        input[key.to_sym]
      end
    end

    def exact_keys!(input, keys)
      invalid! unless input.is_a?(Hash) && input.size <= keys.size && input.keys.all? { |key| key.is_a?(String) && keys.include?(key) }
    end

    def scalar(key, value)
      return reason_codes(value) if REASON_KEYS.include?(key)
      return enum(value, CANDIDATE_IDS) if %w[candidate_id selected_candidate_id].include?(key)
      return enum(value, ENUMS.fetch(key)) if ENUMS.key?(key)
      if BOOLEAN_KEYS.include?(key)
        invalid! unless value == true || value == false
        return value
      end
      if key == "schema_version"
        invalid! unless value.is_a?(Integer) && value == 1
        return value
      end
      if key == "index"
        invalid! unless value.is_a?(Integer) && value.between?(0, MAX_SOURCE_COUNT)
        return value
      end
      number(value)
    end

    def enum(value, allowed)
      value = value.to_s if !@strict && value.is_a?(Symbol)
      invalid! unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 128 && allowed.include?(value)
      value.dup
    end

    def reason_codes(value)
      invalid! unless value.is_a?(Array) && value.size <= 32
      value.map { |reason| enum(reason, REASONS + REASONS.map(&:upcase)) }
    end

    def number(value)
      if value.is_a?(Integer)
        invalid! if value.abs > MAX_NUMBER
        return value
      end
      if !@strict && value.is_a?(BigDecimal)
        invalid! unless value.finite? && value.exponent.between?(-112, 15) && value.precision <= 128
        value = value.to_s("F")
      elsif !@strict && value.is_a?(Rational)
        value = rational_decimal(value)
      end
      invalid! unless value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? && value.bytesize <= 128
      invalid! unless NUMBER_PATTERN.match?(value)
      value.dup
    end

    def integer_number(value)
      normalized = number(value)
      invalid! unless normalized.is_a?(Integer) || /\A-?(?:0|[1-9][0-9]{0,14})\z/.match?(normalized)
      normalized
    end

    def rational_decimal(value)
      invalid! if value.numerator.bit_length > 425 || value.denominator.bit_length > 425
      denominator = value.denominator
      twos = 0
      fives = 0
      while (denominator % 2).zero?
        denominator /= 2
        twos += 1
      end
      while (denominator % 5).zero?
        denominator /= 5
        fives += 1
      end
      invalid! unless denominator == 1
      scale = [ twos, fives ].max
      invalid! if scale > 112
      scaled = value.numerator * (2**(scale - twos)) * (5**(scale - fives))
      return scaled.to_s if scale.zero?

      digits = scaled.abs.to_s.rjust(scale + 1, "0")
      "#{scaled.negative? ? '-' : ''}#{digits[0...-scale]}.#{digits[-scale..]}"
    end

    def invalid!
      raise Invalid
    end

    def bounded_json!(value, depth = 0)
      invalid! if depth > 12
      case value
      when Hash
        invalid! if value.size > 128
        consume_read_bytes!(2 + [ value.size - 1, 0 ].max)
        value.each do |key, child|
          invalid! unless key.is_a?(String)
          bounded_json!(key, depth + 1)
          consume_read_bytes!(1)
          bounded_json!(child, depth + 1)
        end
      when Array
        invalid! if value.size > MAX_ROWS
        consume_read_bytes!(2 + [ value.size - 1, 0 ].max)
        value.each { |child| bounded_json!(child, depth + 1) }
      when String
        invalid! unless value.bytesize <= 128 && value.valid_encoding? && value.encoding.ascii_compatible?
        consume_read_bytes!(JSON.generate(value).bytesize)
      when Integer
        invalid! if value.abs > MAX_NUMBER
        consume_read_bytes!(value.to_s.bytesize)
      when true, false, nil
        consume_read_bytes!(value == true ? 4 : value == false ? 5 : 4)
      else
        invalid!
      end
    end

    def consume_read_bytes!(bytes)
      @read_budget -= bytes
      invalid! if @read_budget.negative?
    end
  end
end
