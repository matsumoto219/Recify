module Admin
  class CurrentAmountInspectorPresenter
    MAX_ROWS = 20
    MAX_REASONS = 32
    MAX_NUMBER = 999_999_999_999_999
    ROUNDING_MODES = %w[floor round ceil].freeze
    ROUNDING_SCOPES = %w[per_tax_rate_group per_item per_receipt].freeze
    BASES = %w[
      receipt_input_preserved
      external_tax_from_receipt
      items_as_tax_excluded
      items_as_tax_included
      mixed_by_tax_rate_group
      printed_tax_details_gross
      printed_tax_details_net
      printed_tax_details_raw_sum
      incomplete_tax_details_receipt_tax
    ].freeze
    REASONS = %w[
      total_mismatch
      total_amount_mismatch
      subtotal_amount_mismatch
      item_total_mismatch
      tax_amount_mismatch
      tax_detail_mismatch
      invalid_amount_relation
      payment_amount_mismatch
      tax_details_double_counted
      tax_detail_gross_item_mismatch
      unsupported_tax_detail_gross_basis
      adjustment_uncertain
      insufficient_data
      ocr_total_mismatch
      tax_detail_rate_mismatch
      tax_detail_incomplete
      tax_detail_partial
      item_tax_rate_group_uncertain
      zero_amount_item_incomplete
      discount_data_incomplete
      adjustment_tax_rate_missing
      price_tax_inclusion_uncertain
      competing_exact_basis_candidate
      mixed_basis_search_truncated
      calculation_profile_uncertain
      purchase_adjustment_tax_allocation_uncertain
    ].freeze
    SCORE_KEYS = %w[
      receipt_total_delta
      receipt_subtotal_delta
      receipt_tax_delta
      payment_delta
      receipt_input_item_delta
      warning_penalty
      hard_reject_penalty
      rounding_mode_penalty
      external_tax_exact_tax_bonus
      basis_penalty
    ].freeze
    TOTAL_KEYS = %w[
      total_amount
      subtotal_amount
      tax_amount
      adjusted_item_total
      adjustment_discount_total
      adjustment_surcharge_total
      purchase_adjustment_total
      payment_adjustment_total
      payment_amount_sum
      final_payment_total
      adjustment_tax_rate_missing_total
    ].freeze
    CANDIDATE_KEYS = %w[
      candidate_id
      basis
      subtotal
      tax
      purchase_total
      final_payment_total
      purchase_adjustment_total
      payment_adjustment_total
      payment_amount_sum
      rounding_mode
      rounding_scope
      score
      score_breakdown
      warnings
      hard_reject_reasons
      evidence
      computed_items
    ].freeze
    PROFILE_KEYS = %w[
      tax_rounding_mode
      discount_rounding_mode
      receipt_tax_basis
      item_amount_basis
      tax_detail_amount_basis
    ].freeze
    EVIDENCE_KEYS = %w[
      source
      index
      rate
      basis
      formula
      amount
      printed_amount
      printed_amount_basis
      net_amount
      gross_amount
      tax_amount
      target_net_amount
      target_tax_amount
      target_gross_amount
      purchase_total
      final_payment_total
      payment_amount_sum
      payment_delta
      payment_amount_mismatch_suppressed
      suppressed_reason
      effect
      kind
      sign
      tax_rate
      tax_rate_source
    ].freeze
    ITEM_KEYS = %w[
      price
      quantity
      quantity_unit_code
      original_line_total
      line_total
      discount_amount
      discount_rate
      tax_rate
      amount_price_present
      amount_quantity_present
      amount_line_total_present
      amount_discount_amount_present
    ].freeze
    ENUMS = {
      "context" => %w[analysis manual edit_save],
      "selected_candidate_status" => %w[accepted rejected],
      "selected_basis" => BASES,
      "rounding_mode" => ROUNDING_MODES,
      "rounding_scope" => ROUNDING_SCOPES,
      "tax" => ROUNDING_MODES,
      "discount" => ROUNDING_MODES,
      "tax_rounding_mode" => ROUNDING_MODES,
      "discount_rounding_mode" => ROUNDING_MODES,
      "receipt_tax_basis" => %w[total_includes_tax tax_added_to_subtotal],
      "item_amount_basis" => %w[line_total_as_recorded line_total_as_net mixed_by_tax_rate_group],
      "tax_detail_amount_basis" => %w[gross net unknown],
      "source" => %w[receipt_items receipt_tax_detail receipt_input receipt_adjustment receipt_payments amount_engine],
      "formula" => BASES,
      "printed_amount_basis" => %w[gross net tax_only summary intermediate unknown],
      "effect" => %w[purchase_adjustment payment_adjustment unknown_adjustment],
      "kind" => ReceiptAdjustment::KINDS,
      "sign" => ReceiptAdjustment::SIGNS,
      "tax_rate_source" => %w[explicit inherited_single_rate unknown not_applicable],
      "suppressed_reason" => %w[tendered_like_overpayment]
    }.freeze
    BOOLEAN_KEYS = %w[
      safe_to_auto_complete
      no_safe_candidate
      payment_amount_mismatch_suppressed
      amount_price_present
      amount_quantity_present
      amount_line_total_present
      amount_discount_amount_present
    ].freeze
    EVIDENCE_BASES = %w[gross net tax_only summary intermediate unknown tax_included tax_excluded non_taxable].freeze
    CANDIDATE_IDS = (
      %w[analysis_receipt_input manual_receipt_input edit_saved_input] +
      %w[mixed_by_tax_rate_group printed_tax_details_gross printed_tax_details_net printed_tax_details_raw_sum external_tax_from_receipt].product(ROUNDING_MODES).map { |parts| parts.join("/") } +
      [ "incomplete_tax_details_receipt_tax/floor" ] +
      %w[items_as_tax_included items_as_tax_excluded].product(ROUNDING_MODES, ROUNDING_SCOPES).map { |parts| parts.join("/") } +
      [ "items_as_tax_excluded" ].product(ROUNDING_MODES, ROUNDING_SCOPES, [ "original_line_total" ]).map { |parts| parts.join("/") }
    ).freeze

    attr_reader :data, :state, :engine_state

    def initialize(profile)
      @omitted = false
      @data = {}
      @engine_state = :missing
      @state = if profile.nil? || profile == {}
        :missing
      elsif supported_version?(profile)
        :available
      else
        :unavailable
      end
      @data = sanitize_profile(profile) if state == :available
    end

    def omitted?
      @omitted
    end

    def selected_candidate
      data.dig("amount_engine", "selected_candidate") || {}
    end

    def candidates
      data.dig("amount_engine", "candidates") || []
    end

    def evidence
      selected_candidate["evidence"] || []
    end

    def computed_items
      selected_candidate["computed_items"] || []
    end

    def rows(fields)
      fields.map { |key, field| [ I18n.t("admin.current_amount_inspector.labels.#{key}"), value(field) ] }
    end

    def value(field)
      return I18n.t("admin.current_amount_inspector.not_recorded") if field.nil?
      return I18n.t("admin.current_amount_inspector.#{field ? 'yes' : 'no'}") if field == true || field == false
      return field.to_s unless field.is_a?(String) && translated_value?(field)

      I18n.t("admin.current_amount_inspector.values.#{field}")
    end

    def reasons(values)
      return [ I18n.t("admin.current_amount_inspector.not_recorded") ] if values.nil?
      return [ I18n.t("admin.current_amount_inspector.none") ] if values.empty?

      values.map { |reason| I18n.t("admin.current_amount_inspector.reasons.#{reason.downcase}") }
    end

    private

    def supported_version?(profile)
      profile.is_a?(Hash) && profile["schema_version"].is_a?(Integer) && profile["schema_version"] == 1
    end

    def translated_value?(field)
      ENUMS.values.any? { |values| values.include?(field) } || EVIDENCE_BASES.include?(field)
    end

    def sanitize_profile(profile)
      keys = %w[schema_version context profile rounding_mode computed resolved score warnings mismatch_codes blocking_mismatch_codes warning_mismatch_codes selected_candidate_status safe_to_auto_complete amount_engine]
      fields(profile, keys) do |key, field|
        case key
        when "profile"
          fields(field, PROFILE_KEYS + [ "item_amount_basis_assignments" ]) do |name, child|
            if name == "item_amount_basis_assignments"
              records(child) { |entry| scalar_fields(entry, %w[tax_rate basis net_amount tax_amount gross_amount]) }
            else
              scalar(name, child)
            end
          end
        when "rounding_mode"
          scalar_fields(field, %w[tax discount])
        when "computed", "resolved"
          scalar_fields(field, TOTAL_KEYS + [ "tax_detail_amount_basis" ])
        when "amount_engine"
          sanitize_engine(field)
        else
          scalar(key, field)
        end
      end
    end

    def sanitize_engine(engine)
      unless supported_version?(engine)
        @engine_state = :unavailable
        return omit
      end

      @engine_state = :available
      fields(engine, %w[schema_version selected_candidate_id selected_basis selected_candidate_status no_safe_candidate selected_candidate candidates]) do |key, field|
        case key
        when "selected_candidate"
          sanitize_candidate(field, detailed: true)
        when "candidates"
          records(field) { |candidate| sanitize_candidate(candidate, detailed: false) }
        else
          scalar(key, field)
        end
      end
    end

    def sanitize_candidate(candidate, detailed:)
      fields(candidate, CANDIDATE_KEYS) do |key, field|
        case key
        when "score_breakdown"
          scalar_fields(field, SCORE_KEYS)
        when "evidence"
          records(field) { |entry| scalar_fields(entry, EVIDENCE_KEYS) } if detailed
        when "computed_items"
          records(field) { |item| scalar_fields(item, ITEM_KEYS) } if detailed
        when "basis"
          enum(field, BASES)
        when "tax"
          number(field)
        else
          scalar(key, field)
        end
      end
    end

    def scalar_fields(input, keys)
      fields(input, keys) { |key, field| scalar(key, field) }
    end

    def fields(input, keys)
      return omit unless input.is_a?(Hash)

      known_count = keys.count { |key| input.key?(key) }
      omit if input.size > known_count
      keys.each_with_object({}) do |key, result|
        next unless input.key?(key)
        next if input[key].nil?

        sanitized = yield(key, input[key])
        result[key] = sanitized unless sanitized.nil?
      end
    end

    def records(input)
      return omit unless input.is_a?(Array)

      omit if input.size > MAX_ROWS
      input.first(MAX_ROWS).filter_map { |entry| yield(entry) }
    end

    def scalar(key, field)
      return reason_codes(field) if %w[warnings mismatch_codes blocking_mismatch_codes warning_mismatch_codes hard_reject_reasons].include?(key)
      return enum(field, CANDIDATE_IDS) if %w[candidate_id selected_candidate_id].include?(key)
      return enum(field, EVIDENCE_BASES) if key == "basis"
      return field == true || field == false ? field : omit if BOOLEAN_KEYS.include?(key)
      return field == 1 && field.is_a?(Integer) ? field : omit if key == "schema_version"
      return field.is_a?(Integer) && field.between?(0, 1_000_000) ? field : omit if key == "index"
      return enum(field, ENUMS.fetch(key)) if ENUMS.key?(key)
      return enum(field, ReceiptQuantityUnit::UNITS.map(&:code)) if key == "quantity_unit_code"

      number(field)
    end

    def enum(field, values)
      field.is_a?(String) && field.valid_encoding? && field.bytesize <= 128 && values.include?(field) ? field.dup : omit
    end

    def number(field)
      return field.abs <= MAX_NUMBER ? field : omit if field.is_a?(Integer)
      return omit unless field.is_a?(String) && field.valid_encoding? && field.bytesize <= 128
      return omit unless field.encoding.ascii_compatible?
      return omit unless /\A-?(?:0|[1-9][0-9]{0,14})(?:\.[0-9]{1,112})?\z/.match?(field)

      field.dup
    end

    def reason_codes(input)
      return omit unless input.is_a?(Array)

      omit if input.size > MAX_REASONS
      allowed = REASONS + REASONS.map(&:upcase)
      result = input.first(MAX_REASONS).filter_map { |reason| enum(reason, allowed) }
      return omit if result.empty? && input.any?

      result
    end

    def omit
      @omitted = true
      nil
    end
  end
end
